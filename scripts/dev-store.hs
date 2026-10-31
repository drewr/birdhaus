#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson pkgs.base64-bytestring ])"

-- Stand up (or update) the dev store: a second storefront at
-- https://dev.birdhaus.store that talks to its own `birdhausdev` database on
-- the shared Postgres, in Stripe test mode, isolated from production data.
--
-- Idempotent: safe to re-run. It reuses the general-purpose scripts rather than
-- repeating them, so the dev environment is reproducible from the repo:
--   1. ensures the birdhausdev database and role exist on the Postgres instance
--      (the entrypoint also reconciles it on boot, since it is in postgres
--      deploy.hs's DATABASES; this creates it live without a restart);
--   2. creates birdhaus-stripe-test from Stripe test keys in the environment;
--   3. runs store-db-secret.hs for birdhaus-store-dev-db (PG* + a dev webhook);
--   4. if OIDC_CLIENT_ID/OIDC_CLIENT_SECRET are set, runs store-auth-secret.hs
--      for birdhaus-store-dev-auth so dev has accounts; otherwise deploys
--      guest-only and prints the one manual step (create the client in Rauthy's
--      Admin UI, which has no headless path);
--   5. deploys with run.hs.
--
-- Prerequisites: datumctl and gh on PATH (run.hs needs gh with write:packages);
-- the Postgres deployment is running with birdhausdev's password in
-- --db-secret; ghcr-drewr can pull from GHCR. Secrets:
--   export STRIPE_TEST_SECRET_KEY=sk_test_... STRIPE_TEST_PUBLISHABLE_KEY=pk_test_...
-- and, to enable accounts, after creating the dev client in Rauthy:
--   read -rs OIDC_CLIENT_SECRET && export OIDC_CLIENT_SECRET
--   export OIDC_CLIENT_ID=<id>
-- Run from the repo root: ./scripts/dev-store.hs --project P

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
import Turtle

data Opts = Opts
  { session :: Maybe Text
  , project :: Text
  , location :: Text
  , domain :: Text
  , workload :: Text
  , pgInstance :: Text
  , dbName :: Text
  , dbSecret :: Text
  , storeDbSecret :: Text
  , stripeSecret :: Text
  , authSecret :: Text
  , pullSecret :: Text
  }

parser :: Parser Opts
parser =
  Opts
    <$> optional (optText "session" 's' "datumctl session (default: the active session)")
    <*> optText "project" 'p' "Datum Cloud project"
    <*> opt "location" 'l' "us-east-1" "Compute location"
    <*> opt "domain" 'd' "dev.birdhaus.store" "Public hostname for the dev store"
    <*> opt "workload" 'w' "birdhaus-store-dev" "Dev workload name"
    <*> opt "pg-instance" 'g' "birdhaus-pg-default-us-east-1-0" "Postgres instance name (for live database creation)"
    <*> opt "db-name" 'n' "birdhausdev" "Dev database and role name"
    <*> opt "db-secret" 'D' "birdhaus-db-db" "Secret holding the database passwords"
    <*> opt "store-db-secret" 'b' "birdhaus-store-dev-db" "Dev store database Secret to create"
    <*> opt "stripe-secret" 'k' "birdhaus-stripe-test" "Dev Stripe (test keys) Secret"
    <*> opt "auth-secret" 'A' "birdhaus-store-dev-auth" "Dev OIDC Secret (created only if OIDC_CLIENT_* are set)"
    <*> opt "pull-secret" 'r' "ghcr-drewr" "dockerconfigjson Secret used to pull from GHCR"
  where
    opt n short def help =
      optText n short (Specific (HelpMessage (help <> " (default: " <> def <> ")"))) <|> pure def

main :: IO ()
main = do
  o <- options "Stand up or update the dev store" parser
  for_ (session o) (export "DATUM_SESSION")
  export "DATUM_PROJECT" (project o)
  onPath <- findExecutableOrDie "datumctl"
  _ <- findExecutableOrDie "gh"
  let sess = maybe [] (\s -> ["--session", s]) (session o)
      dcOut args = do
        (code, out) <- procStrict "datumctl" (args <> ["--project", project o] <> sess) empty
        unless (code == ExitSuccess) $ die ("datumctl " <> T.unwords args <> " failed")
        pure (T.strip out)
      secretExists n = do
        (code, _, _) <- procStrictWithErr "datumctl" (["get", "secret", n, "--project", project o] <> sess) empty
        pure (code == ExitSuccess)

  ensureDevDatabase o sess dcOut
  ensureStripeTest o sess secretExists
  ensureStoreDbSecret o sess secretExists
  haveAuth <- ensureAuthSecret o sess secretExists

  echo "Deploying the dev store with run.hs..."
  procs "./run.hs"
    ( [ "--project", project o
      , "--workload", workload o
      , "--domain", domain o
      , "--db-secret", storeDbSecret o
      , "--stripe-secret", stripeSecret o
      , "--auth-secret", if haveAuth then authSecret o else authSecret o <> "-absent"
      , "--pull-secret", pullSecret o
      ] <> maybe [] (\s -> ["--session", s]) (session o)
    )
    empty
  echo ""
  printf ("Dev store deployed: https://" % s % "\n") (domain o)
  unless haveAuth $ do
    echo "Accounts are OFF (guest-only). To enable them:"
    printf ("  1. In Rauthy's Admin UI create a client with redirect https://" % s % "/api/auth/callback\n") (domain o)
    echo "  2. read -rs OIDC_CLIENT_SECRET && export OIDC_CLIENT_SECRET; export OIDC_CLIENT_ID=<id>"
    echo "  3. re-run this script."

-- The birdhausdev role and database, created live so no Postgres restart is
-- needed. Mirrors the entrypoint's reconcile and is idempotent. The password
-- comes from the db-secret (postgres deploy.hs generates it for each database
-- in DATABASES), so the live role matches what a restore would reconcile.
ensureDevDatabase :: Opts -> [Text] -> ([Text] -> IO Text) -> IO ()
ensureDevDatabase o sess dcOut = do
  printf ("Ensuring database " % s % " on " % s % "...\n") (dbName o) (pgInstance o)
  encoded <- dcOut ["get", "secret", dbSecret o, "-o", "jsonpath={.data." <> dbName o <> "}"]
  pw <- case Base64.decode (T.encodeUtf8 encoded) of
    Right v | let t = T.decodeUtf8 v, not (T.null t) -> pure t
    _ -> die ("No password for " <> dbName o <> " in Secret " <> dbSecret o <> "; add it (postgres/README.md) and redeploy Postgres")
  let d = dbName o
      remote =
        T.intercalate "; "
          [ "P() { gosu postgres psql -X -qAt -v ON_ERROR_STOP=1 -d postgres \"$@\"; }"
          , "P -tc \"select 1 from pg_roles where rolname='" <> d <> "'\" | grep -q 1 || P -c \"create role " <> d <> " login\""
          , "P -c \"alter role " <> d <> " password '" <> pw <> "'\""
          , "P -tc \"select 1 from pg_database where datname='" <> d <> "'\" | grep -q 1 || P -c \"create database " <> d <> " owner " <> d <> "\""
          , "P -c \"revoke connect on database " <> d <> " from public\" -c \"grant connect on database " <> d <> " to " <> d <> "\""
          ]
  procs "datumctl" (["compute", "exec", pgInstance o, "--project", project o] <> sess <> ["--", "sh", "-c", remote]) empty

ensureStripeTest :: Opts -> [Text] -> (Text -> IO Bool) -> IO ()
ensureStripeTest o _ secretExists = do
  have <- secretExists (stripeSecret o)
  if have then printf ("Secret " % s % " exists.\n") (stripeSecret o)
  else do
    sk <- envOrDie "STRIPE_TEST_SECRET_KEY"
    pk <- envOrDie "STRIPE_TEST_PUBLISHABLE_KEY"
    unless ("sk_test_" `T.isPrefixOf` sk) $ die "STRIPE_TEST_SECRET_KEY must be a test key (sk_test_...)"
    printf ("Creating Secret " % s % " from Stripe test keys...\n") (stripeSecret o)
    let manifest = A.object
          [ "apiVersion" .= ("v1" :: Text), "kind" .= ("Secret" :: Text)
          , "metadata" .= A.object ["name" .= stripeSecret o, "namespace" .= ("default" :: Text)]
          , "type" .= ("Opaque" :: Text)
          , "stringData" .= A.object [ "STRIPE_SECRET_KEY" .= sk, "STRIPE_PUBLISHABLE_KEY" .= pk ]
          ]
    procs "datumctl" (["create", "-f", "-", "--project", project o] <> maybe [] (\s -> ["--session", s]) (session o))
      (select (textToLines (T.decodeUtf8 (BL.toStrict (A.encode manifest)))))

ensureStoreDbSecret :: Opts -> [Text] -> (Text -> IO Bool) -> IO ()
ensureStoreDbSecret o sess secretExists = do
  have <- secretExists (storeDbSecret o)
  if have then printf ("Secret " % s % " exists.\n") (storeDbSecret o)
  else do
    printf ("Creating Secret " % s % " (registers a test-mode Stripe webhook)...\n") (storeDbSecret o)
    procs "./scripts/store-db-secret.hs"
      ( [ "--project", project o
        , "--name", storeDbSecret o
        , "--db-name", dbName o
        , "--stripe-secret", stripeSecret o
        , "--webhook-url", "https://" <> domain o <> "/api/stripe-webhook"
        ] <> sess
      )
      empty

-- Accounts are optional. store-auth-secret.hs packages a client that must
-- already exist in Rauthy (no headless path to create it); OIDC_CLIENT_SECRET
-- is read from the environment by that script.
ensureAuthSecret :: Opts -> [Text] -> (Text -> IO Bool) -> IO Bool
ensureAuthSecret o sess secretExists = do
  have <- secretExists (authSecret o)
  if have then do printf ("Secret " % s % " exists; accounts enabled.\n") (authSecret o); pure True
  else do
    clientId <- need "OIDC_CLIENT_ID"
    clientSecret <- need "OIDC_CLIENT_SECRET"
    case (clientId, clientSecret) of
      (Just cid, Just cs) | not (T.null (T.strip cid)) && not (T.null (T.strip cs)) -> do
        printf ("Creating Secret " % s % " for dev accounts...\n") (authSecret o)
        procs "./scripts/store-auth-secret.hs"
          ( [ "--project", project o
            , "--name", authSecret o
            , "--client-id", T.strip cid
            , "--redirect", "https://" <> domain o <> "/api/auth/callback"
            , "--internal-url", "http://auth-internal.birdhaus.store:8080"
            ] <> sess
          )
          empty
        pure True
      _ -> do
        echo "OIDC_CLIENT_ID/OIDC_CLIENT_SECRET not set: deploying dev guest-only."
        pure False

findExecutableOrDie :: Text -> IO ()
findExecutableOrDie name = do
  found <- which (fromText name)
  when (isNothing found) $ die (name <> " not found on PATH")

envOrDie :: Text -> IO Text
envOrDie name = do
  v <- need name
  case v of
    Just value | not (T.null (T.strip value)) -> pure (T.strip value)
    _ -> die ("Set " <> name <> " before running")
