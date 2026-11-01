#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson ])"

-- Create the store's Secret holding a Rauthy API key, which email sign-in uses
-- to look up, create and verify accounts (docs/design/login-page.md).
--
-- Create the key in Rauthy's Admin UI → API Keys with Users: read, create and
-- update (one per store: prod and dev). The key is read from $RAUTHY_API_KEY,
-- never from a command line:
--
--   read -rs RAUTHY_API_KEY && export RAUTHY_API_KEY
--   ./scripts/store-rauthy-key.hs --project P [--name birdhaus-store-dev-rauthy]
--
-- Redeploy the store with run.hs (--rauthy-secret) to use it. Delete the
-- Secret and re-run to rotate.

{-# LANGUAGE OverloadedStrings #-}

import qualified Data.Aeson as A
import Data.Aeson ((.=))
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
  }

parser :: Parser Opts
parser =
  Opts
    <$> optional (optText "session" 's' "datumctl session (default: the active session)")
    <*> optText "project" 'p' "Datum Cloud project"
    <*> opt "name" 'n' "birdhaus-store-rauthy" "Secret to create"
  where
    opt n short def help =
      optText n short (Specific (HelpMessage (help <> " (default: " <> def <> ")"))) <|> pure def

main :: IO ()
main = do
  o <- options "Create the store's Rauthy API key Secret" parser
  for_ (session o) (export "DATUM_SESSION")
  given <- need "RAUTHY_API_KEY"
  key <- case given of
    Just value | not (T.null (T.strip value)) -> pure (T.strip value)
    _ -> die "Set RAUTHY_API_KEY (read -rs RAUTHY_API_KEY) before running"
  -- Rauthy shows the key as `<name>$<secret>`; the header needs both parts.
  unless ("$" `T.isInfixOf` key) $ die "RAUTHY_API_KEY should look like <name>$<secret>, as Rauthy shows it"

  (exists, _, _) <- procStrictWithErr "datumctl" ["get", "secret", secretName o, "--project", project o] empty
  when (exists == ExitSuccess) $
    die ("Secret " <> secretName o <> " already exists; delete it to rotate the key")

  -- `create` rather than `apply`, which would copy the value into a
  -- plaintext last-applied-configuration annotation.
  let manifest = A.object
        [ "apiVersion" .= ("v1" :: Text), "kind" .= ("Secret" :: Text)
        , "metadata" .= A.object ["name" .= secretName o, "namespace" .= ("default" :: Text)]
        , "type" .= ("Opaque" :: Text)
        , "stringData" .= A.object ["RAUTHY_API_KEY" .= key]
        ]
  procs "datumctl" ["create", "-f", "-", "--project", project o]
    (select (textToLines (T.decodeUtf8 (BL.toStrict (A.encode manifest)))))
  printf ("Created Secret " % s % ". Redeploy the store to use it.\n") (secretName o)
