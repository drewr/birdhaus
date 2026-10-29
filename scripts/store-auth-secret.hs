#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson ])"
#! nix-shell -p openssl

-- Create the store's Secret birdhaus-store-auth: the Rauthy issuer and client
-- that /api/auth uses, plus the key that signs session cookies.
--
-- The client secret is read from $OIDC_CLIENT_SECRET, never from a command
-- line. Create the client in Rauthy's Admin UI first (auth/README.md), then:
--
--   read -rs OIDC_CLIENT_SECRET && export OIDC_CLIENT_SECRET
--   ./scripts/store-auth-secret.hs --project P --client-id <id>
--
-- Redeploy the store with run.hs to use it. Delete the Secret to rotate.

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
  , issuer :: Text
  , clientId :: Text
  , redirect :: Text
  }

parser :: Parser Opts
parser =
  Opts
    <$> optional (optText "session" 's' "datumctl session (default: the active session)")
    <*> optText "project" 'p' "Datum Cloud project"
    <*> opt "name" 'n' "birdhaus-store-auth" "Secret to create"
    <*> opt "issuer" 'i' "https://login.birdhaus.store" "Rauthy issuer URL"
    <*> optText "client-id" 'c' "OIDC client ID from Rauthy"
    <*> opt "redirect" 'r' "https://birdhaus.store/api/auth/callback" "Callback URL registered for the client"
  where
    opt n short def help =
      optText n short (Specific (HelpMessage (help <> " (default: " <> def <> ")"))) <|> pure def

main :: IO ()
main = do
  o <- options "Create the store's OIDC and session Secret" parser
  for_ (session o) (export "DATUM_SESSION")
  unless ("https://" `T.isPrefixOf` issuer o) $ die "--issuer must be an https:// URL"
  unless ("https://" `T.isPrefixOf` redirect o) $ die "--redirect must be an https:// URL"
  clientSecret <- need "OIDC_CLIENT_SECRET"
  secret <- case clientSecret of
    Just value | not (T.null (T.strip value)) -> pure (T.strip value)
    _ -> die "Set OIDC_CLIENT_SECRET (read -rs OIDC_CLIENT_SECRET) before running"

  (exists, _, _) <- procStrictWithErr "datumctl" ["get", "secret", secretName o, "--project", project o] empty
  when (exists == ExitSuccess) $
    die ("Secret " <> secretName o <> " already exists; delete it to rotate the session key")

  sessionKey <- T.strip . snd <$> procStrict "openssl" ["rand", "-hex", "32"] empty

  -- `create` rather than `apply`, which would copy the values into a
  -- plaintext last-applied-configuration annotation.
  let manifest = A.object
        [ "apiVersion" .= ("v1" :: Text), "kind" .= ("Secret" :: Text)
        , "metadata" .= A.object ["name" .= secretName o, "namespace" .= ("default" :: Text)]
        , "type" .= ("Opaque" :: Text)
        , "stringData" .= A.object
            [ "OIDC_ISSUER" .= issuer o
            , "OIDC_CLIENT_ID" .= clientId o
            , "OIDC_CLIENT_SECRET" .= secret
            , "OIDC_REDIRECT_URI" .= redirect o
            , "SESSION_SECRET" .= sessionKey
            ]
        ]
  procs "datumctl" ["create", "-f", "-", "--project", project o]
    (select (textToLines (T.decodeUtf8 (BL.toStrict (A.encode manifest)))))
  printf ("Created Secret " % s % ". Redeploy the store with run.hs to enable sign-in.\n") (secretName o)
