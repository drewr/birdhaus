#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.base64-bytestring ])"
#! nix-shell -p nodejs_22 gh git colima

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
-- The pre-order batch is set here: --cap, --closes and --ship-by. Raising the
-- cap or moving a date is a redeploy.

{-# LANGUAGE OverloadedStrings #-}

import qualified Control.Foldl as Fold
import qualified Data.ByteString.Base64 as Base64
import Data.Foldable (for_)
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Optional (Optional (Specific))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import System.Directory (doesFileExist, findExecutable, getHomeDirectory, getTemporaryDirectory)
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
  , pullSecret :: Text
  , domain :: Text
  , imageTag :: Maybe Text
  , batch :: Text
  , cap :: Maybe Text
  , closes :: Text
  , shipBy :: Text
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
    <*> optText "pull-secret" 'r' "dockerconfigjson Secret used to pull from GHCR"
    <*> opt "domain" 'd' "birdhaus.store" "Public hostname"
    <*> optional (optText "tag" 't' "Image tag (default: UTC timestamp)")
    <*> opt "batch" 'B' "xmas-2026" "Pre-order batch ID"
    <*> (Just <$> opt "cap" 'c' "20" "Units the batch can sell")
    <*> opt "closes" 'C' "2026-12-01" "Last day of pre-orders, YYYY-MM-DD (US Central)"
    <*> opt "ship-by" 'S' "2026-12-15" "Ship-by date promised at checkout, YYYY-MM-DD"
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
  for_ (cap o) $ \c ->
    unless (T.all (`elem` ['0' .. '9']) c && not (T.null c)) $ die ("--cap must be a whole number, not " <> c)
  for_ [stripeSecret o, dbSecret o, pullSecret o] $ \s -> do
    ok <- dcQuiet ["get", "secret", s]
    unless ok $ die ("Secret " <> s <> " not found in project " <> project o)
  -- Accounts are optional: without the Secret the store runs as a guest-only
  -- storefront (scripts/store-auth-secret.hs creates it).
  haveAuth <- dcQuiet ["get", "secret", authSecret o]
  unless haveAuth $ T.putStrLn ("No Secret " <> authSecret o <> ": deploying without accounts.")

  echo "Building the storefront..."
  procs "npm" ["ci"] empty
  procs "npm" ["run", "build"] empty

  buildkit <- ensureBuildkit
  ghUser <- T.toLower . T.strip . snd <$> procStrict "gh" ["api", "user", "--jq", ".login"] empty
  tag <- maybe timestamp pure (imageTag o)
  let image = "ghcr.io/" <> ghUser <> "/" <> imageName o <> ":" <> tag

  tmp <- getTemporaryDirectory
  digestRef <- with (mktempdir tmp "birdhaus") $ \dir -> do
    ghToken <- T.strip . snd <$> procStrict "gh" ["auth", "token", "--hostname", "github.com"] empty
    writeDockerConfig dir ghUser ghToken
    export "DOCKER_CONFIG" (T.pack dir)
    printf ("Building and pushing " % s % "...\n") image
    out <- fold (streamLines (inprocWithErr datumctl
      [ "compute", "build", "--project", project o, "--buildkit-host", buildkit
      , "--push", "--output", image, "." ] empty)) Fold.list
    unset "DOCKER_CONFIG"
    maybe (die "Could not find the pushed digest in the build output") pure (pushedDigest out)

  with (mktempdir tmp "birdhaus") $ \dir -> do
    let workloadFile = dir </> "workload.yaml"
        serviceFile = dir </> "service.yaml"
    T.writeFile workloadFile (workloadManifest o haveAuth digestRef)
    T.writeFile serviceFile (serviceManifest o)
    printf ("Deploying " % s % " to " % s % " in " % s % "...\n") digestRef (location o) (project o)
    dc ["compute", "deploy", "-f", T.pack workloadFile, "--yes"]
    dc ["apply", "-f", T.pack serviceFile]

  (_, canonical) <- procStrict datumctl
    ["get", "httpproxy", workload o, "-o", "jsonpath={.status.canonicalHostname}", "--project", project o] empty
  printf ("Deployed: https://" % s % " (also https://" % s % ")\n") (domain o) canonical

-- Builds go through the BuildKit inside the containerd-runtime colima VM.
ensureBuildkit :: IO Text
ensureBuildkit = do
  home <- getHomeDirectory
  let sock = home </> ".colima/default/buildkitd.sock"
  (status, _, _) <- procStrictWithErr "colima" ["status"] empty
  unless (status == ExitSuccess) $ do
    echo "Starting colima..."
    procs "colima" ["start"] empty
  present <- doesFileExist sock
  unless present $ die ("No BuildKit socket at " <> T.pack sock <> "; is colima using the containerd runtime?")
  pure ("unix://" <> T.pack sock)

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

timestamp :: IO Text
timestamp = T.pack . formatTime defaultTimeLocale "%Y%m%d%H%M%S" <$> getCurrentTime

workloadManifest :: Opts -> Bool -> Text -> Text
workloadManifest o auth image =
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
    , "      minReplicas: 1"
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
    , "            - name: BATCH_CAP"
    , "              value: \"" <> fromMaybe "" (cap o) <> "\""
    , "            - name: BATCH_CLOSES_AT"
    , "              value: \"" <> closes o <> "\""
    , "            - name: BATCH_SHIP_BY"
    , "              value: \"" <> shipBy o <> "\""
    , "            envFrom:"
    , "            - secretRef:"
    , "                name: " <> stripeSecret o
    , "            - secretRef:"
    , "                name: " <> dbSecret o
    ]
      <> (if auth then ["            - secretRef:", "                name: " <> authSecret o] else [])
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
