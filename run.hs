#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.base64-bytestring pkgs.aeson ])"
#! nix-shell -p nodejs_22 gh git curl

-- Build the storefront, push it to GHCR as a Compute image, and deploy it to
-- Datum Compute behind https://birdhaus.store.
--
-- Prerequisites: datumctl is on PATH (it is not in nixpkgs); gh is logged in
-- with write:packages; the project has a
-- Secret with STRIPE_SECRET_KEY and STRIPE_PUBLISHABLE_KEY (--stripe-secret),
-- the database and webhook Secret from scripts/store-db-secret.hs
-- (--db-secret), and a dockerconfigjson Secret that can pull from GHCR
-- (--pull-secret); the domain's DNSZone is verified and delegated to Datum.
--
-- Orders are recorded under --batch. How many are left is the inventory, edited
-- at /admin/inventory.
--
-- The version (also the image tag) comes from git: vX.Y.Z at a release tag,
-- otherwise vX.Y.(Z+1)-dev.N. The deploy finishes when the domain serves that
-- version with its migrations applied (/api/health).

{-# LANGUAGE OverloadedStrings #-}

import qualified Control.Foldl as Fold
import Control.Monad (filterM)
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Base64 as Base64
import Data.Char (isAlphaNum, isDigit)
import Data.Foldable (for_)
import Data.List ((\\))
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Optional (Optional (Specific))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import System.Directory (findExecutable, getTemporaryDirectory)
import System.FilePath ((</>))
import Turtle hiding (FilePath, (</>))

data Opts = Opts
  { session :: Maybe Text
  , project :: Text
  , location :: Text
  , workload :: Text
  , network :: Text
  , imageName :: Text
  , stripeSecret :: Text
  , dbSecret :: Text
  , authSecret :: Text
  , mailSecret :: Text
  , rauthySecret :: Text
  , pullSecret :: Text
  , domain :: Text
  , version :: Maybe Text
  , batch :: Text
  , alertEmail :: Maybe Text
  , adminGroup :: Text
  , replicas :: Text
  , registryUser :: Maybe Text
  }

parser :: Parser Opts
parser =
  Opts
    <$> optional (optText "session" 's' "datumctl session (default: the active session)")
    <*> optText "project" 'p' "Datum Cloud project"
    <*> opt "location" 'l' "us-east-1" "Compute location"
    <*> opt "workload" 'w' "birdhaus-store" "Workload name"
    <*> opt "network" 'N' "birdhaus" "Datum Network (VPC) to attach"
    <*> opt "image-name" 'i' "birdhaus-store" "GHCR package name"
    <*> opt "stripe-secret" 'k' "birdhaus-stripe" "Secret holding the Stripe keys"
    <*> opt "db-secret" 'b' "birdhaus-store-db" "Secret with PG* settings and STRIPE_WEBHOOK_SECRET (scripts/store-db-secret.hs)"
    <*> opt "auth-secret" 'A' "birdhaus-store-auth" "Secret with the OIDC settings and session key (scripts/store-auth-secret.hs)"
    <*> opt "mail-secret" 'M' "birdhaus-ses" "Secret with the SES SMTP settings, for emailed sign-in codes"
    <*> opt "rauthy-secret" 'R' "birdhaus-store-rauthy" "Secret with the Rauthy API key (scripts/store-rauthy-key.hs)"
    <*> optText "pull-secret" 'r' "dockerconfigjson Secret used to pull from GHCR"
    <*> opt "domain" 'd' "birdhaus.store" "Public hostname"
    <*> optional (optText "version" 'V' "Version and image tag; vX.Y.Z needs that tag on HEAD (default: from git)")
    <*> opt "batch" 'B' "xmas-2026" "Batch that orders are recorded under"
    <*> optional (optText "alert-email" 'a' "Where to email low-stock alerts (default: none, only logged)")
    <*> opt "admin-group" 'G' "birdhaus-admins" "Rauthy group whose members get the store admin portal"
    -- Two instances so a rollout replaces one while the other keeps serving;
    -- with one, every deploy is a short 503 from the edge.
    <*> opt "replicas" 'n' "2" "Instances to run"
    -- A CI token can't call `gh api user`, so Actions passes the repo owner.
    <*> optional (optText "registry-user" 'u' "GHCR owner to push to (default: the signed-in gh user)")
  where
    opt name short def help =
      optText name short (Specific (HelpMessage (help <> " (default: " <> def <> ")"))) <|> pure def

main :: IO ()
main = do
  o <- options "Build and deploy the Birdhaus store to Datum Compute" parser
  for_ (session o) (export "DATUM_SESSION")
  export "DATUM_PROJECT" (project o)
  let datumctl = "datumctl"
  onPath <- findExecutable "datumctl"
  when (isNothing onPath) $ die "datumctl not found on PATH"
  let dc args = procs datumctl (args <> ["--project", project o]) empty
      dcQuiet args = do
        (code, _, _) <- procStrictWithErr datumctl (args <> ["--project", project o]) empty
        pure (code == ExitSuccess)

  (ghCode, _) <- procStrict "gh" ["auth", "status", "--hostname", "github.com"] empty
  unless (ghCode == ExitSuccess) $
    die "Authenticate gh with write:packages: gh auth login --hostname github.com --scopes write:packages"
  procs datumctl (["whoami"] <> maybe [] (\s -> ["--session", s]) (session o)) empty
  let r = replicas o
  unless (not (T.null r) && T.all (`elem` ['0' .. '9']) r && T.take 1 r /= "0") $
    die ("--replicas must be a positive whole number, not " <> r)
  for_ [stripeSecret o, dbSecret o, pullSecret o] $ \s -> do
    ok <- dcQuiet ["get", "secret", s]
    unless ok $ die ("Secret " <> s <> " not found in project " <> project o)
  ver <- maybe gitVersion pure (version o)
  unless (T.isPrefixOf "v" ver && T.all (\c -> isAlphaNum c || c `elem` (".-" :: String)) ver) $
    die ("Not a version: " <> ver)
  -- A release version must be what's checked out: prod runs exactly the tag.
  unless ("-" `T.isInfixOf` ver) $ do
    (_, tags) <- procStrict "git" ["tag", "--points-at", "HEAD"] empty
    unless (ver `elem` map T.strip (T.lines tags)) $ die (ver <> " is a release version, but HEAD is not tagged " <> ver)
  commit <- T.strip . snd <$> procStrict "git" ["rev-parse", "HEAD"] empty
  T.putStrLn ("Version " <> ver <> " (" <> commit <> ")")
  -- Accounts are optional: without the Secret the store runs as a guest-only
  -- storefront (scripts/store-auth-secret.hs creates it).
  haveAuth <- dcQuiet ["get", "secret", authSecret o]
  unless haveAuth $ T.putStrLn ("No Secret " <> authSecret o <> ": deploying without accounts.")
  -- Email sign-in needs both; without them only Google sign-in is offered.
  optionalSecrets <- filterM (\n -> dcQuiet ["get", "secret", n]) [mailSecret o, rauthySecret o]
  for_ ([mailSecret o, rauthySecret o] \\ optionalSecrets) $ \n ->
    T.putStrLn ("No Secret " <> n <> ": deploying without email sign-in.")

  echo "Building the storefront..."
  procs "npm" ["ci"] empty
  procs "npm" ["run", "build"] empty

  ghUser <- T.toLower . T.strip <$> case registryUser o of
    Just user -> pure user
    Nothing -> snd <$> procStrict "gh" ["api", "user", "--jq", ".login"] empty
  let image = "ghcr.io/" <> ghUser <> "/" <> imageName o <> ":" <> ver

  tmp <- getTemporaryDirectory
  digestRef <- with (mktempdir tmp "birdhaus") $ \dir -> do
    ghToken <- T.strip . snd <$> procStrict "gh" ["auth", "token", "--hostname", "github.com"] empty
    writeDockerConfig dir ghUser ghToken
    export "DOCKER_CONFIG" (T.pack dir)
    printf ("Building and pushing " % s % "...\n") image
    -- By default datumctl uses the container engine's BuildKit (honoring
    -- DOCKER_HOST/DOCKER_CONTEXT); BUILDKIT_HOST overrides it.
    out <- fold (streamLines (inprocWithErr datumctl
      [ "compute", "build", "--project", project o
      , "--push", "--output", image, "." ] empty)) Fold.list
    unset "DOCKER_CONFIG"
    maybe (die "Could not find the pushed digest in the build output") pure (pushedDigest out)

  with (mktempdir tmp "birdhaus") $ \dir -> do
    let workloadFile = dir </> "workload.yaml"
        serviceFile = dir </> "service.yaml"
    T.writeFile workloadFile (workloadManifest o haveAuth optionalSecrets ver commit digestRef)
    T.writeFile serviceFile (serviceManifest o)
    printf ("Deploying " % s % " to " % s % " in " % s % "...\n") digestRef (location o) (project o)
    -- The proxy first, so its health check already covers this rollout.
    dc ["apply", "-f", T.pack serviceFile]
    dc ["compute", "deploy", "-f", T.pack workloadFile, "--yes"]

  (_, canonical) <- procStrict datumctl
    ["get", "httpproxy", workload o, "-o", "jsonpath={.status.canonicalHostname}", "--project", project o] empty
  printf ("Waiting for https://" % s % " to serve " % s % " with migrations applied...\n") (domain o) ver
  awaitRollout (domain o) ver
  printf ("Deployed " % s % ": https://" % s % " (also https://" % s % ")\n") ver (domain o) canonical

-- vX.Y.Z on a release tag. Past one, the next patch plus the commit count, so
-- every commit on main has its own version; uncommitted changes add .dirty so
-- a local deploy is never mistaken for a commit.
gitVersion :: IO Text
gitVersion = do
  (found, described, _) <- procStrictWithErr "git"
    ["describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "--exclude", "*-*"] empty
  let tag = if found == ExitSuccess then Just (T.strip described) else Nothing
  (major, minor, patch) <- case tag of
    Nothing -> pure (0, 0, 0)
    Just t -> maybe (die ("Release tag " <> t <> " is not vX.Y.Z")) pure (parseVersion t)
  (_, count) <- procStrict "git" ["rev-list", "--count", maybe "HEAD" (<> "..HEAD") tag] empty
  (_, changes) <- procStrict "git" ["status", "--porcelain", "--untracked-files=no"] empty
  let n = T.strip count
      v = case tag of
        Just t | n == "0" -> t
        _ -> "v" <> T.intercalate "." (map (T.pack . show) [major, minor, patch + 1]) <> "-dev." <> n
  pure (if T.null (T.strip changes) then v else v <> ".dirty")

parseVersion :: Text -> Maybe (Int, Int, Int)
parseVersion t = do
  parts <- traverse number . T.splitOn "." =<< T.stripPrefix "v" t
  case parts of
    [x, y, z] -> Just (x, y, z)
    _ -> Nothing
  where
    number n
      | not (T.null n) && T.all isDigit n = Just (read (T.unpack n))
      | otherwise = Nothing

-- The instances share the domain, so eight answers in a row must report the
-- new version before the old ones count as gone. Gives up after ten minutes.
awaitRollout :: Text -> Text -> IO ()
awaitRollout host want = go (120 :: Int) (0 :: Int) ""
  where
    go 0 _ seen = die ("Gave up waiting for " <> want <> " on " <> host <> "; /api/health last said: " <> seen)
    go tries streak seen = do
      (_, body, _) <- procStrictWithErr "curl" ["-s", "--max-time", "5", "https://" <> host <> "/api/health"] empty
      let field k = case A.decodeStrict (T.encodeUtf8 body) of
            Just (A.Object m) | Just (A.String v) <- KM.lookup k m -> Just v
            _ -> Nothing
          done = field "version" == Just want && field "migrations" == Just "ok"
          now = maybe (T.take 200 (T.strip body)) (\v -> v <> ", migrations " <> fromMaybe "?" (field "migrations")) (field "version")
      when (now /= seen) $ T.putStrLn ("  " <> now)
      if done && streak >= 7
        then pure ()
        else do
          sleep 5
          go (tries - 1) (if done then streak + 1 else 0) now

-- A throwaway Docker config so datumctl can push to GHCR with the gh token.
writeDockerConfig :: FilePath -> Text -> Text -> IO ()
writeDockerConfig dir user token = do
  let auth = T.decodeUtf8 (Base64.encode (T.encodeUtf8 (user <> ":" <> token)))
  T.writeFile (dir </> "config.json") ("{\"auths\":{\"ghcr.io\":{\"auth\":\"" <> auth <> "\"}}}\n")

streamLines :: Shell (Either Line Line) -> Shell Text
streamLines lines' = do
  l <- lines'
  let t = either lineToText lineToText l
  liftIO (T.putStrLn t)
  pure t

-- "Pushed ghcr.io/x/y:tag (ghcr.io/x/y@sha256:...)" -> "ghcr.io/x/y@sha256:..."
pushedDigest :: [Text] -> Maybe Text
pushedDigest out =
  listToMaybe
    [ T.takeWhile (/= ')') (T.drop 1 rest)
    | l <- reverse out
    , "Pushed " `T.isPrefixOf` l
    , let rest = snd (T.breakOn "(" l)
    , not (T.null rest)
    ]

workloadManifest :: Opts -> Bool -> [Text] -> Text -> Text -> Text -> Text
workloadManifest o auth extraSecrets ver commit image =
  T.unlines $
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
    , "      minReplicas: " <> replicas o
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
    , "        class: unikernel"
    -- The server drains for 10s after SIGTERM, then finishes in-flight
    -- requests (server/index.js); this is the most it waits before a kill.
    , "        terminationGracePeriodSeconds: 30"
    , "        resources:"
    , "          instanceType: datumcloud-d1-standard-2"
    , "        sandbox:"
    , "          imagePullSecrets:"
    , "          - name: " <> pullSecret o
    , "          containers:"
    , "          - name: app"
    , "            image: " <> image
    , "            env:"
    , "            - name: BATCH_ID"
    , "              value: \"" <> batch o <> "\""
    , "            - name: STOCK_ALERT_EMAIL"
    , "              value: \"" <> fromMaybe "" (alertEmail o) <> "\""
    , "            - name: ADMIN_GROUP"
    , "              value: \"" <> adminGroup o <> "\""
    , "            - name: APP_VERSION"
    , "              value: \"" <> ver <> "\""
    , "            - name: APP_COMMIT"
    , "              value: \"" <> commit <> "\""
    , "            envFrom:"
    , "            - secretRef:"
    , "                name: " <> stripeSecret o
    , "            - secretRef:"
    , "                name: " <> dbSecret o
    ]
      <> concat [["            - secretRef:", "                name: " <> n] | n <- [authSecret o | auth] <> extraSecrets]
      <> [ "            ports:"
         , "            - name: http"
         , "              port: 8080"
         , "              protocol: TCP"
         , "            securityContext:"
         , "              capabilities:"
         , "                drop:"
         , "                - ALL"
         ]

-- `compute deploy --http-port` cannot be combined with -f, so declare the
-- NetworkService and HTTPProxy it would create, plus the custom hostname.
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
    -- Datum has no readiness probe, so the edge may route to an instance that
    -- isn't listening yet or has stopped. Envoy counts refused connections as
    -- 5xx too; after three in a row it sets that instance aside for 30s (longer
    -- if it keeps failing), never more than half the instances at once.
    , "  healthCheck:"
    , "    passive:"
    , "      consecutive5xxErrors: 3"
    , "      baseEjectionTime: 30s"
    , "      maxEjectionPercent: 50"
    , "  hostnames:"
    , "  - " <> domain o
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
