#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson pkgs.base64-bytestring ])"
#! nix-shell -p openssl

-- Deploy Umami (visitor analytics) to Datum Compute, backed by the `umami`
-- database of the S3-backed Postgres (postgres/README.md), and publish it at
-- https://stats.birdhaus.store. Datum creates the DNS record for the hostname.
--
-- Prerequisites: datumctl on PATH; the Postgres deployment is running in the
-- same Network, its NAME-db Secret has an `umami` password, and --db-host
-- resolves to its address (dns/aaaa.yaml). The Secret birdhaus-umami
-- (DATABASE_URL, APP_SECRET) is created on first run. Run from the repo root.

{-# LANGUAGE OverloadedStrings #-}

import qualified Data.Aeson as A
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

-- Umami 3.4.1, linux/amd64. Pinned by digest; bump deliberately.
umamiImage :: Text
umamiImage = "ghcr.io/umami-software/umami@sha256:f2c645cc5cdff76e7fbfe4c7eeabc7e363840bd34364f4f719b69d11f9ef1c19"

data Opts = Opts
  { session :: Maybe Text
  , project :: Text
  , location :: Text
  , network :: Text
  , workload :: Text
  , publicHost :: Text
  , dbHost :: Text
  , dbSecret :: Text
  }

parser :: Parser Opts
parser =
  Opts
    <$> optional (optText "session" 's' "datumctl session (default: the active session)")
    <*> optText "project" 'p' "Datum Cloud project"
    <*> opt "location" 'l' "us-east-1" "Compute location"
    <*> opt "network" 'N' "birdhaus" "Datum Network (VPC) to attach"
    <*> opt "workload" 'w' "birdhaus-umami" "Workload name (also the Secret name)"
    <*> opt "hostname" 'H' "stats.birdhaus.store" "Public hostname"
    <*> opt "db-host" 'D' "db.birdhaus.store" "Postgres hostname (a name, not an IPv6 literal)"
    <*> opt "db-secret" 'S' "birdhaus-db-db" "Secret holding the database passwords"
  where
    opt n short def help =
      optText n short (Specific (HelpMessage (help <> " (default: " <> def <> ")"))) <|> pure def

main :: IO ()
main = do
  o <- options "Deploy Umami analytics to Datum Compute" parser
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
    encoded <- dcText ["get", "secret", dbSecret o, "-o", "jsonpath={.data.umami}"]
    pw <- either (const (die ("No umami password in " <> dbSecret o))) (pure . T.decodeUtf8)
      (Base64.decode (T.encodeUtf8 encoded))
    when (T.null pw) $ die ("No umami password in " <> dbSecret o)
    appSecret <- T.strip . snd <$> procStrict "openssl" ["rand", "-hex", "32"] empty
    printf ("Creating Secret " % s % " (database at " % s % ")...\n") (workload o) (dbHost o)
    -- `create` rather than `apply`, which would copy the values into a
    -- plaintext last-applied-configuration annotation. The password is hex,
    -- so it needs no URL escaping. The host is a name because Umami's runtime
    -- driver cannot parse a bracketed IPv6 literal (its migrations can).
    let manifest = A.object
          [ "apiVersion" .= ("v1" :: Text), "kind" .= ("Secret" :: Text)
          , "metadata" .= A.object ["name" .= workload o, "namespace" .= ("default" :: Text)]
          , "type" .= ("Opaque" :: Text)
          , "stringData" .= A.object
              [ "DATABASE_URL" .= ("postgresql://umami:" <> pw <> "@" <> dbHost o <> ":5432/umami")
              , "APP_SECRET" .= appSecret
              ]
          ]
    procs "datumctl" ["create", "-f", "-", "--project", project o]
      (select (textToLines (T.decodeUtf8 (BL.toStrict (A.encode manifest)))))

  tmp <- getTemporaryDirectory
  with (mktempdir tmp "birdhaus") $ \dir -> do
    let workloadFile = dir </> "workload.yaml"
        serviceFile = dir </> "service.yaml"
    T.writeFile workloadFile (workloadManifest o)
    T.writeFile serviceFile (serviceManifest o)
    printf ("Deploying Umami to " % s % " in " % s % "...\n") (location o) (project o)
    dc ["compute", "deploy", "-f", T.pack workloadFile, "--yes"]
    dc ["apply", "-f", T.pack serviceFile]
  printf ("Deployed: https://" % s % "\n") (publicHost o)

-- general-purpose, because Umami's start script runs Prisma migrations as a
-- child process, which a unikernel cannot do. The tracker is served as
-- /t.js and collects at /api/t, names that ad blockers match less often.
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
    , "        class: general-purpose"
    , "        resources:"
    , "          instanceType: datumcloud-d1-standard-2"
    , "        sandbox:"
    , "          containers:"
    , "          - name: umami"
    , "            image: " <> umamiImage
    , "            env:"
    -- The image binds 0.0.0.0 (IPv4 only); instances are IPv6-only.
    , "            - name: HOSTNAME"
    , "              value: \"::\""
    , "            - name: TRACKER_SCRIPT_NAME"
    , "              value: t.js"
    , "            - name: COLLECT_API_ENDPOINT"
    , "              value: /api/t"
    , "            - name: DISABLE_TELEMETRY"
    , "              value: \"1\""
    -- Otherwise every dashboard load calls api.umami.is for update checks.
    , "            - name: DISABLE_UPDATES"
    , "              value: \"1\""
    , "            envFrom:"
    , "            - secretRef:"
    , "                name: " <> workload o
    , "            ports:"
    , "            - name: http"
    , "              port: 3000"
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
    , "    port: 3000"
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
