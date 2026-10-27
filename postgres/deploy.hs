#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson ])"
#! nix-shell -p gh colima openssl

-- Build the Postgres image, push it to GHCR, and deploy it to Datum Compute as
-- a general-purpose workload whose durability lives in S3 (see
-- docs/design/postgres-s3.md).
--
-- Prerequisites: datumctl on PATH; gh logged in with write:packages; a
-- dockerconfigjson Secret that can pull from GHCR (--pull-secret); and the
-- deployment's AWS Secret from `postgres/aws/bootstrap.hs deployment NAME
-- PROJECT`. The database-password Secret NAME-db is created on first deploy
-- with random passwords, one key per database. Run from the repo root.

{-# LANGUAGE OverloadedStrings #-}

import qualified Control.Exception as E
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import Data.Aeson ((.=))
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (for_)
import Data.Maybe (fromMaybe, isNothing)
import Data.Optional (Optional (Specific))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import System.Directory (findExecutable, getTemporaryDirectory)
import System.FilePath ((</>))
import Turtle hiding (FilePath, (</>))

data Opts = Opts
  { session :: Maybe Text
  , project :: Text
  , location :: Text
  , name :: Text
  , network :: Text
  , workloadName :: Maybe Text
  , databases :: [Text]
  , instanceType :: Text
  , pullSecret :: Text
  , imageTag :: Maybe Text
  }

parser :: Parser Opts
parser =
  Opts
    <$> optional (optText "session" 's' "datumctl session (default: the active session)")
    <*> optText "project" 'p' "Datum Cloud project"
    <*> opt "location" 'l' "us-east-1" "Compute location"
    <*> opt "name" 'n' "birdhaus-db" "Deployment name (workload, image and secret prefix)"
    <*> opt "network" 'N' "birdhaus" "Datum Network (VPC) to attach"
    <*> optional (optText "workload" 'w' "Workload name (default: the deployment name)")
    <*> (T.words <$> opt "databases" 'd' "birdhaus umami" "Space-separated databases to create")
    <*> opt "instance-type" 'i' "datumcloud-d1-standard-2" "Compute instance type"
    <*> optText "pull-secret" 'r' "dockerconfigjson Secret used to pull from GHCR"
    <*> optional (optText "tag" 't' "Image tag (default: UTC timestamp)")
  where
    opt n short def help =
      optText n short (Specific (HelpMessage (help <> " (default: " <> def <> ")"))) <|> pure def

main :: IO ()
main = do
  o <- options "Build and deploy the S3-backed Postgres to Datum Compute" parser
  for_ (session o) (export "DATUM_SESSION")
  export "DATUM_PROJECT" (project o)
  let datumctl = "datumctl"
      awsSecret = name o <> "-aws"
      dbSecret = name o <> "-db"
  onPath <- findExecutable "datumctl"
  when (isNothing onPath) $ die "datumctl not found on PATH"
  let dc args = procs datumctl (args <> ["--project", project o]) empty
      exists kind n = do
        (code, _, _) <- procStrictWithErr datumctl ["get", kind, n, "--project", project o] empty
        pure (code == ExitSuccess)

  (ghCode, _) <- procStrict "gh" ["auth", "status", "--hostname", "github.com"] empty
  unless (ghCode == ExitSuccess) $
    die "Authenticate gh with write:packages: gh auth login --hostname github.com --scopes write:packages"
  procs datumctl (["whoami"] <> maybe [] (\s -> ["--session", s]) (session o)) empty
  for_ [pullSecret o, awsSecret] $ \s -> do
    ok <- exists "secret" s
    unless ok $ die ("Secret " <> s <> " not found in project " <> project o <> if s == awsSecret then "; run postgres/aws/bootstrap.hs deployment" else "")

  haveDb <- exists "secret" dbSecret
  if haveDb
    then do
      -- Passwords are read by the entrypoint from files named after databases.
      (_, keys) <- procStrict datumctl ["get", "secret", dbSecret, "-o", "jsonpath={.data}", "--project", project o] empty
      for_ (databases o) $ \d ->
        unless (("\"" <> d <> "\"") `T.isInfixOf` keys) $
          die ("Secret " <> dbSecret <> " has no password for " <> d <> "; add the key or recreate the secret")
    else do
      printf ("Creating Secret " % s % " with random passwords...\n") dbSecret
      pws <- for' (databases o) $ \d -> do
        (_, pw) <- procStrict "openssl" ["rand", "-hex", "24"] empty
        pure (d, T.strip pw)
      -- `create` rather than `apply`, which would copy the passwords into a
      -- plaintext last-applied-configuration annotation.
      let manifest = A.object
            [ "apiVersion" .= ("v1" :: Text), "kind" .= ("Secret" :: Text)
            , "metadata" .= A.object ["name" .= dbSecret, "namespace" .= ("default" :: Text)]
            , "type" .= ("Opaque" :: Text)
            , "stringData" .= A.object [K.fromText d .= pw | (d, pw) <- pws]
            ]
      procs datumctl ["create", "-f", "-", "--project", project o]
        (select (textToLines (T.decodeUtf8 (BL.toStrict (A.encode manifest)))))

  ensureColima
  ghUser <- T.toLower . T.strip . snd <$> procStrict "gh" ["api", "user", "--jq", ".login"] empty
  tag <- maybe timestamp pure (imageTag o)
  let image = "ghcr.io/" <> ghUser <> "/" <> name o <> ":" <> tag

  -- A general-purpose workload runs an ordinary container image, so this
  -- builds with nerdctl (amd64, emulated on Apple silicon). `datumctl compute
  -- build` would produce a unikernel image, which cannot run Postgres.
  let nerdctl args = procs "colima" ("nerdctl" : "--" : args)
  printf ("Building and pushing " % s % "...\n") image
  nerdctl ["build", "--platform", "linux/amd64", "-t", image, "postgres"] empty
  ghToken <- T.strip . snd <$> procStrict "gh" ["auth", "token", "--hostname", "github.com"] empty
  nerdctl ["login", "ghcr.io", "-u", ghUser, "--password-stdin"] (select (textToLines ghToken))
  nerdctl ["push", "--platform", "linux/amd64", image] empty `E.finally` nerdctl ["logout", "ghcr.io"] empty
  (_, inspected) <- procStrict "colima"
    ["nerdctl", "--", "image", "inspect", "--format", "{{index .RepoDigests 0}}", image] empty
  let digestRef = T.strip inspected
  unless ("@sha256:" `T.isInfixOf` digestRef) $ die ("Could not read the pushed digest: " <> digestRef)

  tmp <- getTemporaryDirectory
  with (mktempdir tmp "birdhaus") $ \dir -> do
    let workloadFile = dir </> "workload.yaml"
    T.writeFile workloadFile (workloadManifest o digestRef)
    printf ("Deploying " % s % " to " % s % " in " % s % "...\n") digestRef (location o) (project o)
    dc ["compute", "deploy", "-f", T.pack workloadFile, "--yes"]

  echo "Deployed. Find the address with: datumctl compute instances list (the instance's IPv6 is PGHOST)."

ensureColima :: IO ()
ensureColima = do
  (status, _, _) <- procStrictWithErr "colima" ["status"] empty
  unless (status == ExitSuccess) $ do
    echo "Starting colima..."
    procs "colima" ["start"] empty

timestamp :: IO Text
timestamp = T.pack . formatTime defaultTimeLocale "%Y%m%d%H%M%S" <$> getCurrentTime

for' :: [a] -> (a -> IO b) -> IO [b]
for' = flip mapM

workload :: Opts -> Text
workload o = fromMaybe (name o) (workloadName o)

-- general-purpose (a VM running a normal container), because Postgres needs a
-- writable disk. Retain keeps the instance's IPv6 address across destroy and
-- recreate, so consumers can hold it in configuration.
workloadManifest :: Opts -> Text -> Text
workloadManifest o image =
  T.unlines
    [ "apiVersion: compute.datumapis.com/v1alpha"
    , "kind: Workload"
    , "metadata:"
    , "  name: " <> workload o
    , "spec:"
    , "  placements:"
    , "  - name: default"
    , "    locations:"
    , "    - name: " <> location o
    , "    scaleSettings:"
    , "      instanceManagementPolicy: OrderedReady"
    , "      minReplicas: 1"
    , "  template:"
    , "    spec:"
    , "      networkInterfaces:"
    , "      - name: eth0"
    , "        ipFamilies:"
    , "        - IPv6"
    , "        network:"
    , "          name: " <> network o
    , "        reclaimPolicy: Retain"
    , "      runtime:"
    , "        class: general-purpose"
    , "        resources:"
    , "          instanceType: " <> instanceType o
    , "        sandbox:"
    , "          imagePullSecrets:"
    , "          - name: " <> pullSecret o
    , "          containers:"
    , "          - name: postgres"
    , "            image: " <> image
    , "            env:"
    , "            - name: DATABASES"
    , "              value: \"" <> T.unwords (databases o) <> "\""
    , "            envFrom:"
    , "            - secretRef:"
    , "                name: " <> name o <> "-aws"
    , "            ports:"
    , "            - name: postgres"
    , "              port: 5432"
    , "              protocol: TCP"
    , "            securityContext:"
    , "              allowPrivilegeEscalation: false"
    , "              capabilities:"
    , "                drop:"
    , "                - ALL"
    , "                add:"
    , "                - CHOWN"
    , "                - DAC_OVERRIDE"
    , "                - FOWNER"
    , "                - SETUID"
    , "                - SETGID"
    , "              seccompProfile:"
    , "                type: RuntimeDefault"
    , "            volumeAttachments:"
    , "            - mountPath: /secrets/db"
    , "              name: db-secret"
    , "      volumes:"
    , "      - name: db-secret"
    , "        secret:"
    , "          secretName: " <> name o <> "-db"
    ]
