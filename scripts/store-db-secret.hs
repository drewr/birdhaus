#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson pkgs.base64-bytestring ])"
#! nix-shell -p curl

-- Create a store database Secret: Postgres settings (PG*) for the --db-name
-- database (default `birdhaus`), and STRIPE_WEBHOOK_SECRET for a webhook
-- endpoint this script registers with Stripe for --webhook-url. The dev store
-- reuses it with --name birdhaus-store-dev-db --db-name birdhausdev.
--
-- The database password and the Stripe secret key are read from their Datum
-- Secrets and the signing secret from Stripe's response; none of them touch
-- disk or a command line. Stripe only reveals a signing secret when the
-- endpoint is created, so to rotate, delete both the Secret and the endpoint
-- and run this again. Run from the repo root, then redeploy with run.hs.

{-# LANGUAGE OverloadedStrings #-}

import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson ((.=))
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (for_)
import Data.Optional (Optional (Specific))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Turtle

data Opts = Opts
  { session :: Maybe Text
  , project :: Text
  , secretName :: Text
  , dbSecret :: Text
  , dbName :: Text
  , dbHost :: Text
  , stripeSecret :: Text
  , webhookUrl :: Text
  }

parser :: Parser Opts
parser =
  Opts
    <$> optional (optText "session" 's' "datumctl session (default: the active session)")
    <*> optText "project" 'p' "Datum Cloud project"
    <*> opt "name" 'n' "birdhaus-store-db" "Secret to create"
    <*> opt "db-secret" 'D' "birdhaus-db-db" "Secret holding the database passwords"
    <*> opt "db-name" 'd' "birdhaus" "Database and role name (also the password key in --db-secret)"
    <*> opt "db-host" 'H' "db.birdhaus.store" "Postgres hostname"
    <*> opt "stripe-secret" 'k' "birdhaus-stripe" "Secret holding STRIPE_SECRET_KEY"
    <*> opt "webhook-url" 'u' "https://birdhaus.store/api/stripe-webhook" "Webhook endpoint URL"
  where
    opt n short def help =
      optText n short (Specific (HelpMessage (help <> " (default: " <> def <> ")"))) <|> pure def

main :: IO ()
main = do
  o <- options "Create the store's database and Stripe webhook Secret" parser
  for_ (session o) (export "DATUM_SESSION")
  let datumctl args = do
        (code, out) <- procStrict "datumctl" (args <> ["--project", project o]) empty
        unless (code == ExitSuccess) $ die ("datumctl " <> T.unwords args <> " failed")
        pure (T.strip out)
      secretValue name key = do
        encoded <- datumctl ["get", "secret", name, "-o", "jsonpath={.data." <> key <> "}"]
        case Base64.decode (T.encodeUtf8 encoded) of
          Right v | not (T.null (T.decodeUtf8 v)) -> pure (T.decodeUtf8 v)
          _ -> die ("No " <> key <> " in Secret " <> name)

  (exists, _, _) <- procStrictWithErr "datumctl" ["get", "secret", secretName o, "--project", project o] empty
  when (exists == ExitSuccess) $
    die ("Secret " <> secretName o <> " already exists; delete it (and its Stripe webhook endpoint) to recreate it")

  password <- secretValue (dbSecret o) (dbName o)
  stripeKey <- secretValue (stripeSecret o) "STRIPE_SECRET_KEY"

  endpoints <- stripe stripeKey "GET" "webhook_endpoints?limit=100" []
  let existing = [i | e <- arrayField "data" endpoints, Just u <- [textField "url" e], u == webhookUrl o, Just i <- [textField "id" e]]
  unless (null existing) $
    die ("Stripe already has a webhook endpoint for " <> webhookUrl o <> " (" <> T.intercalate ", " existing <> "); delete it first")

  printf ("Registering a Stripe webhook endpoint for " % s % "...\n") (webhookUrl o)
  created <- stripe stripeKey "POST" "webhook_endpoints"
    [ ("url", webhookUrl o)
    , ("enabled_events[]", "payment_intent.succeeded")
    , ("enabled_events[]", "charge.refunded")
    , ("description", "Birdhaus pre-order records")
    ]
  signing <- maybe (die "Stripe did not return a signing secret") pure (textField "secret" created)
  printf ("Endpoint " % s % " created.\n") (maybe "?" id (textField "id" created))

  -- `create` rather than `apply`, which would copy the values into a
  -- plaintext last-applied-configuration annotation.
  let manifest = A.object
        [ "apiVersion" .= ("v1" :: Text), "kind" .= ("Secret" :: Text)
        , "metadata" .= A.object ["name" .= secretName o, "namespace" .= ("default" :: Text)]
        , "type" .= ("Opaque" :: Text)
        , "stringData" .= A.object
            [ "PGHOST" .= dbHost o
            , "PGPORT" .= ("5432" :: Text)
            , "PGUSER" .= dbName o
            , "PGDATABASE" .= dbName o
            , "PGPASSWORD" .= password
            , "STRIPE_WEBHOOK_SECRET" .= signing
            ]
        ]
  procs "datumctl" ["create", "-f", "-", "--project", project o]
    (select (textToLines (T.decodeUtf8 (BL.toStrict (A.encode manifest)))))
  printf ("Created Secret " % s % ". Redeploy the store with run.hs to use it.\n") (secretName o)

-- A Stripe API call. curl reads the key and the form fields from its stdin
-- config, so neither appears in the process list.
stripe :: Text -> Text -> Text -> [(Text, Text)] -> IO A.Value
stripe key method path fields = do
  let quote v = "\"" <> T.replace "\"" "\\\"" (T.replace "\\" "\\\\" v) <> "\""
      config =
        [ "user = " <> quote (key <> ":")
        , "request = " <> quote method
        , "url = " <> quote ("https://api.stripe.com/v1/" <> path)
        , "silent"
        , "show-error"
        ]
          <> ["data-urlencode = " <> quote (k <> "=" <> v) | (k, v) <- fields]
  (code, out) <- procStrict "curl" ["--config", "-"] (select (textToLines (T.unlines config)))
  unless (code == ExitSuccess) $ die ("Stripe request failed: " <> method <> " " <> path)
  case A.decodeStrict (T.encodeUtf8 out) of
    Just v@(A.Object o) | Just err <- KM.lookup "error" o -> die ("Stripe error: " <> T.pack (show (textField "message" err)) <> " " <> T.pack (show v))
    Just v -> pure v
    Nothing -> die "Stripe returned something that is not JSON"

textField :: Text -> A.Value -> Maybe Text
textField k (A.Object o) = case KM.lookup (K.fromText k) o of
  Just (A.String t) -> Just t
  _ -> Nothing
textField _ _ = Nothing

arrayField :: Text -> A.Value -> [A.Value]
arrayField k (A.Object o) = case KM.lookup (K.fromText k) o of
  Just (A.Array xs) -> foldr (:) [] xs
  _ -> []
arrayField _ _ = []
