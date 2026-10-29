#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson pkgs.base64-bytestring ])"
#! nix-shell -p openssl

-- Deploy Rauthy (accounts and sign-in) to Datum Compute, backed by the `auth`
-- database of the S3-backed Postgres and published at https://login.birdhaus.store.
-- Commands, the Google client and the store client are configured in Rauthy's
-- Admin UI after the first deploy; see auth/README.md.
--
-- Prerequisites: datumctl on PATH; the Postgres workload is running with an
-- `auth` database and password in the NAME-db Secret; the Secret
-- birdhaus-ses holds the SMTP settings; --admin-email is the operator's
-- address. The Secret birdhaus-auth is created on first run. Run from the repo
-- root.

{-# LANGUAGE OverloadedStrings #-}

import Control.Monad (forM, unless, when)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import Data.Aeson ((.=))
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (for_)
import Data.Maybe (isNothing)
import Data.Optional (Optional (Specific))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import System.Directory (findExecutable, getTemporaryDirectory)
import System.FilePath ((</>))
import Turtle hiding (FilePath, (</>))

-- Rauthy 0.37.2, linux/amd64. Pinned by digest; bump deliberately.
rauthyImage :: Text
rauthyImage = "ghcr.io/sebadob/rauthy@sha256:666e9f54b4deb99d710448b32eb2c18214160744dd3f68f8f7cee140a6cd80ef"

data Opts = Opts
  { session :: Maybe Text
  , project :: Text
  , location :: Text
  , network :: Text
  , workload :: Text
  , publicHost :: Text
  , dbHost :: Text
  , dbSecret :: Text
  , dbName :: Text
  , smtpSecret :: Text
  , adminEmail :: Text
  , trustedProxies :: Text
  , instanceType :: Text
  }

parser :: Parser Opts
parser =
  Opts
    <$> optional (optText "session" 's' "datumctl session (default: the active session)")
    <*> optText "project" 'p' "Datum Cloud project"
    <*> opt "location" 'l' "us-east-1" "Compute location"
    <*> opt "network" 'N' "birdhaus" "Datum Network (VPC) to attach"
    <*> opt "workload" 'w' "birdhaus-auth" "Workload name (also the Secret name)"
    <*> opt "hostname" 'H' "login.birdhaus.store" "Public hostname (no scheme)"
    <*> opt "db-host" 'D' "db.birdhaus.store" "Postgres hostname (a name, not an IPv6 literal)"
    <*> opt "db-secret" 'S' "birdhaus-db-db" "Secret holding the database passwords"
    <*> opt "db-name" 'd' "auth" "Database name (the Postgres DATABASES list must include it)"
    <*> opt "smtp-secret" 'm' "birdhaus-ses" "Secret with the SMTP settings"
    <*> optText "admin-email" 'a' "Email address for the bootstrap admin"
    <*> opt "trusted-proxies" 't' "0.0.0.0/0 ::/0" "Edge proxy CIDRs, space separated (narrow after the spike)"
    <*> opt "instance-type" 'i' "datumcloud-d1-standard-2" "Compute instance type"
  where
    opt n short def help =
      optText n short (Specific (HelpMessage (help <> " (default: " <> def <> ")"))) <|> pure def

main :: IO ()
main = do
  o <- options "Deploy Rauthy accounts and sign-in to Datum Compute" parser
  for_ (session o) (export "DATUM_SESSION")
  export "DATUM_PROJECT" (project o)
  onPath <- findExecutable "datumctl"
  when (isNothing onPath) $ die "datumctl not found on PATH"
  let dc args = procs "datumctl" (args <> ["--project", project o]) empty
      dcText args = do
        (code, out) <- procStrict "datumctl" (args <> ["--project", project o]) empty
        unless (code == ExitSuccess) $ die ("datumctl " <> T.unwords args <> " failed")
        pure (T.strip out)
      exists kind n = do
        (code, _, _) <- procStrictWithErr "datumctl" ["get", kind, n, "--project", project o] empty
        pure (code == ExitSuccess)

  haveSecret <- exists "secret" (workload o)
  unless haveSecret $ do
    dbPassword <- readSecretKey (project o) (dbSecret o) (dbName o)
    smtp <- readSmtp (project o) (smtpSecret o)
    encId <- randHex 4
    encKey <- randB64 32
    adminPassword <- randHex 24
    let proxies = T.intercalate "\n" (T.words (trustedProxies o))
        manifest = A.object
          [ "apiVersion" .= ("v1" :: Text), "kind" .= ("Secret" :: Text)
          , "metadata" .= A.object ["name" .= workload o, "namespace" .= ("default" :: Text)]
          , "type" .= ("Opaque" :: Text)
          , "stringData" .= A.object
              ( [ "HIQLITE" .= ("false" :: Text)
                , "PG_HOST" .= dbHost o
                , "PG_PORT" .= ("5432" :: Text)
                , "PG_DB_NAME" .= dbName o
                , "PG_USER" .= dbName o
                , "PG_PASSWORD" .= dbPassword
                , "PG_TLS" .= ("disable" :: Text)
                , "PUB_URL" .= publicHost o
                , "LISTEN_SCHEME" .= ("http" :: Text)
                , "LISTEN_ADDRESS" .= ("::" :: Text)
                , "PORT_HTTP" .= ("8080" :: Text)
                , "PROXY_MODE" .= ("true" :: Text)
                , "TRUSTED_PROXIES" .= proxies
                , "HTTP_WORKERS" .= ("1" :: Text)
                , "ENC_KEYS" .= (encId <> "/" <> encKey)
                , "ENC_KEY_ACTIVE" .= encId
                , "RP_ID" .= publicHost o
                , "RP_ORIGIN" .= ("https://" <> publicHost o)
                , "RP_NAME" .= ("Birdhaus" :: Text)
                , "BOOTSTRAP_ADMIN_EMAIL" .= adminEmail o
                , "BOOTSTRAP_ADMIN_PASSWORD_PLAIN" .= adminPassword
                , "OPEN_USER_REG" .= ("true" :: Text)
                ]
                  <> [K.fromText k .= v | (k, v) <- smtp]
              )
          ]
    printf ("Creating Secret " % s % " (database " % s % " at " % s % ")...\n") (workload o) (dbName o) (dbHost o)
    -- `create` rather than `apply`, which would copy the values into a
    -- plaintext last-applied-configuration annotation.
    procs "datumctl" ["create", "-f", "-", "--project", project o]
      (select (textToLines (jsonText manifest)))

  tmp <- getTemporaryDirectory
  with (mktempdir tmp "birdhaus") $ \dir -> do
    let workloadFile = dir </> "workload.yaml"
        serviceFile = dir </> "service.yaml"
    T.writeFile workloadFile (workloadManifest o)
    T.writeFile serviceFile (serviceManifest o)
    printf ("Deploying Rauthy to " % s % " in " % s % "...\n") (location o) (project o)
    dc ["compute", "deploy", "-f", T.pack workloadFile, "--yes"]
    dc ["apply", "-f", T.pack serviceFile]
  printf ("Deployed: https://" % s % "\n") (publicHost o)
  echo ""
  echo "Remaining manual steps:"
  printf ("  1. Bootstrap admin password: datumctl get secret " % s % " -o jsonpath='{.data.BOOTSTRAP_ADMIN_PASSWORD_PLAIN}' --project " % s % " | base64 -d\n") (workload o) (project o)
  printf ("  2. Sign in at https://" % s % "/admin as " % s % ", then change the password and force MFA.\n") (publicHost o) (adminEmail o)
  printf ("  3. Google OAuth client, redirect https://" % s % "/auth/v1/providers/callback, added in Providers.\n") (publicHost o)
  printf ("  4. Store client redirect: https://birdhaus.store/api/auth/callback (PKCE S256).\n")

-- ---------------------------------------------------------------- secrets

-- A key from a Datum Secret, base64-decoded. Never printed.
readSecretKey :: Text -> Text -> Text -> IO Text
readSecretKey project secret key = do
  let args = ["get", "secret", secret, "-o", "jsonpath={.data." <> key <> "}", "--project", project]
  (code, out) <- procStrict "datumctl" args empty
  let encoded = T.strip out
  unless (code == ExitSuccess && not (T.null encoded) && encoded /= "None") $
    die ("No `" <> key <> "` in Secret " <> secret <> "; add it and redeploy Postgres (see postgres/README.md)")
  case Base64.decode (T.encodeUtf8 encoded) of
    Left _ -> die ("Cannot decode `" <> key <> "` from Secret " <> secret)
    Right raw -> pure (T.strip (T.decodeUtf8 raw))

-- SMTP settings from their own Secret, copied into the Rauthy Secret.
readSmtp :: Text -> Text -> IO [(Text, Text)]
readSmtp project secret =
  forM ["SMTP_URL", "SMTP_PORT", "SMTP_USERNAME", "SMTP_PASSWORD", "SMTP_FROM"] $ \k ->
    (,) k <$> readSecretKey project secret k

randHex :: Int -> IO Text
randHex n = T.strip . snd <$> procStrict "openssl" ["rand", "-hex", T.pack (show n)] empty

randB64 :: Int -> IO Text
randB64 n =
  T.filter (`notElem` ['\n', '\r']) . snd <$> procStrict "openssl" ["rand", "-base64", T.pack (show n)] empty

-- ---------------------------------------------------------------- manifests

workloadManifest :: Opts -> Text
workloadManifest o =
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
    , "      scaleSettings:"
    , "        instanceManagementPolicy: OrderedReady"
    , "        minReplicas: 1"
    , "  template:"
    , "    spec:"
    , "      networkInterfaces:"
    , "      - name: eth0"
    , "        ipFamilies:"
    , "        - IPv6"
    , "        network:"
    , "          name: " <> network o
    , "        reclaimPolicy: Delete"
    , "      runtime:"
    , "        class: general-purpose"
    , "        resources:"
    , "          instanceType: " <> instanceType o
    , "        sandbox:"
    , "          containers:"
    , "          - name: rauthy"
    , "            image: " <> rauthyImage
    , "            envFrom:"
    , "            - secretRef:"
    , "                name: " <> workload o
    , "            ports:"
    , "            - name: http"
    , "              port: 8080"
    , "              protocol: TCP"
    , "            securityContext:"
    , "              allowPrivilegeEscalation: false"
    , "              capabilities:"
    , "                drop:"
    , "                - ALL"
    , "              seccompProfile:"
    , "                type: RuntimeDefault"
    ]

serviceManifest :: Opts -> Text
serviceManifest o =
  T.unlines
    [ "apiVersion: networking.datumapis.com/v1alpha"
    , "kind: NetworkService"
    , "metadata:"
    , "  name: " <> workload o
    , "spec:"
    , "  networkInterfaces:"
    , "    selector:"
    , "      matchLabels:"
    , "        compute.datumapis.com/workload-name: " <> workload o
    , "  ports:"
    , "  - name: http"
    , "    port: 8080"
    , "    protocol: TCP"
    , "  trafficDistribution:"
    , "    strategy: Nearest"
    , "---"
    , "apiVersion: networking.datumapis.com/v1alpha"
    , "kind: HTTPProxy"
    , "metadata:"
    , "  name: " <> workload o
    , "spec:"
    , "  hostnames:"
    , "  - " <> publicHost o
    , "  rules:"
    , "  - backends:"
    , "    - networkService:"
    , "        name: " <> workload o
    , "        port: http"
    , "      weight: 1"
    , "    matches:"
    , "    - path:"
    , "        type: PathPrefix"
    , "        value: /"
    ]

jsonText :: A.ToJSON a => a -> Text
jsonText = T.decodeUtf8 . BL.toStrict . A.encode
