#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson pkgs.cryptonite ])"
#! nix-shell -p awscli2

-- Create the SES SMTP user for Rauthy and the birdhaus-ses Datum Secret.
-- Needs IAM admin credentials (root or an admin profile); the drewr user
-- cannot create IAM users.
--
--   AWS_PROFILE=drewr-root ./scripts/ses-smtp.hs --project P
--   AWS_PROFILE=drewr-root ./scripts/ses-smtp.hs --project P --rotate
--
-- The IAM user may only send as the verified domain. The SMTP password is
-- derived from the access key and never touches a command line or stdout.
-- Re-running without --rotate refuses to replace an existing key.

{-# LANGUAGE OverloadedStrings #-}

import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac)
import qualified Data.Aeson as A
import Data.Aeson ((.=))
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (forM_, for_)
import Data.Optional (Optional (Specific))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Turtle

data Opts = Opts
  { session :: Maybe Text
  , project :: Text
  , profile :: Maybe Text
  , userName :: Text
  , domain :: Text
  , region :: Text
  , secretName :: Text
  , from :: Text
  , rotate :: Bool
  }

parser :: Parser Opts
parser =
  Opts
    <$> optional (optText "session" 's' "datumctl session (default: the active session)")
    <*> optText "project" 'p' "Datum Cloud project for the Secret"
    <*> optional (optText "aws-profile" 'P' "AWS profile (default: the environment's)")
    <*> opt "user" 'u' "birdhaus-ses-smtp" "IAM user name"
    <*> opt "domain" 'd' "birdhaus.store" "Verified SES domain identity"
    <*> opt "region" 'r' "us-east-1" "AWS region"
    <*> opt "name" 'n' "birdhaus-ses" "Datum Secret to create"
    <*> opt "from" 'f' "Birdhaus <info@birdhaus.store>" "From address"
    <*> switch "rotate" 'R' "Replace an existing access key and Secret"
  where
    opt n short def help =
      optText n short (Specific (HelpMessage (help <> " (default: " <> def <> ")"))) <|> pure def

main :: IO ()
main = do
  o <- options "Create the SES SMTP user and its Datum Secret" parser
  for_ (session o) (export "DATUM_SESSION")

  acct <- awsText o ["sts", "get-caller-identity", "--query", "Account", "--output", "text"]
  secretExists <- datumOk o
  when (secretExists && not (rotate o)) $
    die ("Secret " <> secretName o <> " already exists; pass --rotate to replace it")
  ensureUser o
  oldKeys <- accessKeys o
  when (not (null oldKeys) && not (rotate o)) $
    die (userName o <> " already has an access key; pass --rotate to replace it")

  putPolicy o acct
  (keyId, secretKey) <- newKey o
  let smtp = smtpPassword (region o) secretKey
  when secretExists $ procs "datumctl" ["delete", "secret", secretName o, "--project", project o] empty
  createSecret o keyId smtp
  -- Only after the new Secret exists, so a failure leaves the old key usable.
  forM_ oldKeys $ \k -> aws_ o ["iam", "delete-access-key", "--user-name", userName o, "--access-key-id", k]

  printf ("IAM user " % s % " may send as " % s % ".\n") (userName o) (domain o)
  printf ("Created Secret " % s % " (SMTP user " % s % ", from " % s % ").\n") (secretName o) keyId (from o)
  printf ("Next: ./auth/deploy.hs --project " % s % " --admin-email <operator email> --smtp-secret " % s % "\n") (project o) (secretName o)

-- ---------------------------------------------------------------- AWS

aws :: Opts -> [Text] -> IO (ExitCode, Text, Text)
aws o args = do
  let prefix = ["--region", region o] <> maybe [] (\p -> ["--profile", p]) (profile o)
  (code, out, err) <- procStrictWithErr "aws" (prefix <> args) empty
  pure (code, T.strip out, T.strip err)

awsText :: Opts -> [Text] -> IO Text
awsText o args = do
  (code, out, err) <- aws o args
  when (code /= ExitSuccess) $
    die ("aws " <> T.unwords (take 2 args) <> " failed: " <> err)
  pure out

aws_ :: Opts -> [Text] -> IO ()
aws_ o = void . awsText o

awsOk :: Opts -> [Text] -> IO Bool
awsOk o args = (\(code, _, _) -> code == ExitSuccess) <$> aws o args

ensureUser :: Opts -> IO ()
ensureUser o = do
  exists <- awsOk o ["iam", "get-user", "--user-name", userName o]
  unless exists $
    aws_ o ["iam", "create-user", "--user-name", userName o, "--path", "/birdhaus/", "--tags", "Key=purpose,Value=birdhaus-auth"]

putPolicy :: Opts -> Text -> IO ()
putPolicy o acct = do
  let arn = "arn:aws:ses:" <> region o <> ":" <> acct <> ":identity/" <> domain o
      document = A.object
        [ "Version" .= ("2012-10-17" :: Text)
        , "Statement" .= [A.object
            [ "Effect" .= ("Allow" :: Text)
            , "Action" .= (["ses:SendEmail", "ses:SendRawEmail"] :: [Text])
            , "Resource" .= arn
            ]]
        ]
  aws_ o ["iam", "put-user-policy", "--user-name", userName o, "--policy-name", "birdhaus-ses-smtp", "--policy-document", jsonText document]

accessKeys :: Opts -> IO [Text]
accessKeys o =
  T.words <$> awsText o ["iam", "list-access-keys", "--user-name", userName o, "--query", "AccessKeyMetadata[].AccessKeyId", "--output", "text"]

newKey :: Opts -> IO (Text, Text)
newKey o = do
  out <- awsText o ["iam", "create-access-key", "--user-name", userName o, "--query", "AccessKey.[AccessKeyId,SecretAccessKey]", "--output", "text"]
  case T.words out of
    [k, s] -> pure (k, s)
    _ -> die "Unexpected output from create-access-key"

-- The SigV4-style chain from the SES documentation:
-- base64(0x04 || HMAC(...HMAC(HMAC(HMAC("AWS4"+secret, "11111111"), region), "ses"),
-- "aws4_request"), "SendRawEmail"))
smtpPassword :: Text -> Text -> Text
smtpPassword region secret =
  T.decodeUtf8 (BAE.convertToBase BAE.Base64 (BS.cons 4 (BA.convert kMessage :: BS.ByteString)))
  where
    sign :: BS.ByteString -> BS.ByteString -> HMAC SHA256
    sign key message = hmac key message
    kDate = sign ("AWS4" <> T.encodeUtf8 secret) "11111111"
    kRegion = sign (BA.convert kDate :: BS.ByteString) (T.encodeUtf8 region)
    kService = sign (BA.convert kRegion :: BS.ByteString) "ses"
    kTerminal = sign (BA.convert kService :: BS.ByteString) "aws4_request"
    kMessage = sign (BA.convert kTerminal :: BS.ByteString) "SendRawEmail"

-- ---------------------------------------------------------------- Datum

datumOk :: Opts -> IO Bool
datumOk o = do
  (code, _, _) <- procStrictWithErr "datumctl" ["get", "secret", secretName o, "--project", project o] empty
  pure (code == ExitSuccess)

createSecret :: Opts -> Text -> Text -> IO ()
createSecret o keyId smtp = do
  let manifest = A.object
        [ "apiVersion" .= ("v1" :: Text), "kind" .= ("Secret" :: Text)
        , "metadata" .= A.object ["name" .= secretName o, "namespace" .= ("default" :: Text)]
        , "type" .= ("Opaque" :: Text)
        , "stringData" .= A.object
            [ "SMTP_URL" .= ("email-smtp." <> region o <> ".amazonaws.com")
            , "SMTP_PORT" .= ("587" :: Text)
            , "SMTP_USERNAME" .= keyId
            , "SMTP_PASSWORD" .= smtp
            , "SMTP_FROM" .= from o
            ]
        ]
  -- `create`, not `apply`: apply would copy the SMTP password into a plaintext
  -- last-applied-configuration annotation.
  procs "datumctl" ["create", "-f", "-", "--project", project o]
    (select (textToLines (T.decodeUtf8 (BL.toStrict (A.encode manifest)))))

jsonText :: A.ToJSON a => a -> Text
jsonText = T.decodeUtf8 . BL.toStrict . A.encode
