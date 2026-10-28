#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson ])"
#! nix-shell -p awscli2 zip openssl

-- birdhaus-watch: heartbeat and probe alerting in AWS (ops/watch/README.md).
-- Uses whatever AWS credentials the environment provides (AWS_PROFILE, SSO).
--
--   ./ops/watch/deploy.hs deploy --to EMAIL --project DATUM_PROJECT
--   ./ops/watch/deploy.hs status
--   ./ops/watch/deploy.hs sweep          run the 5-minute sweep now
--   ./ops/watch/deploy.hs test-alert     send a test email
--
-- deploy is idempotent. It creates or updates the SES identities, the
-- DynamoDB table, the Lambda and its public Function URL, the schedules, and
-- the Datum Secret birdhaus-db-watch that the Postgres watchdog pings with.
-- Check tokens are generated once and kept; they never reach a command line.

{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_, unless, void, when)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import System.Directory (getTemporaryDirectory)
import System.FilePath ((</>))
import qualified System.Process as P
import Turtle hiding (FilePath, (</>))

data Cmd = Deploy Text Text | Status | Sweep | TestAlert

region, name, domain, from :: Text
region = "us-east-1"
name = "birdhaus-watch"
domain = "birdhaus.store"
from = "birdhaus alerts <alerts@birdhaus.store>"

main :: IO ()
main = do
  cmd <- options "Deploy and operate birdhaus-watch alerting" $
    subcommand "deploy" "Create or update everything"
      (Deploy <$> optText "to" 't' "Email address that receives alerts" <*> optText "project" 'p' "Datum project (for the birdhaus-db-watch Secret)")
      <|> subcommand "status" "Show every check's state" (pure Status)
      <|> subcommand "sweep" "Run the sweep now" (pure Sweep)
      <|> subcommand "test-alert" "Send a test email" (pure TestAlert)
  case cmd of
    Deploy to project -> deploy to project
    Status -> status
    Sweep -> invoke "{\"task\":\"sweep\"}"
    TestAlert -> invoke "{\"task\":\"test-alert\"}" >> echo "Sent; check the inbox (and spam)."

-- ---------------------------------------------------------------- deploy

deploy :: Text -> Text -> IO ()
deploy to project = do
  acct <- awsText ["sts", "get-caller-identity", "--query", "Account", "--output", "text"]
  let tableArn = "arn:aws:dynamodb:" <> region <> ":" <> acct <> ":table/" <> name
      functionArn = "arn:aws:lambda:" <> region <> ":" <> acct <> ":function:" <> name

  echo "SES identities..."
  haveDomain <- awsOk ["sesv2", "get-email-identity", "--email-identity", domain]
  unless haveDomain $ aws_ ["sesv2", "create-email-identity", "--email-identity", domain]
  dkim <- T.words <$> awsText ["sesv2", "get-email-identity", "--email-identity", domain, "--query", "DkimAttributes.Tokens", "--output", "text"]
  verified <- awsText ["sesv2", "get-email-identity", "--email-identity", domain, "--query", "VerifiedForSendingStatus", "--output", "text"]
  haveTo <- awsOk ["sesv2", "get-email-identity", "--email-identity", to]
  unless haveTo $ do
    aws_ ["sesv2", "create-email-identity", "--email-identity", to]
    echo "SES sent a verification email to the alert address; click its link once."

  echo "DynamoDB table..."
  haveTable <- awsOk ["dynamodb", "describe-table", "--table-name", name]
  unless haveTable $ do
    aws_ [ "dynamodb", "create-table", "--table-name", name, "--billing-mode", "PAY_PER_REQUEST"
         , "--attribute-definitions", "AttributeName=check,AttributeType=S"
         , "--key-schema", "AttributeName=check,KeyType=HASH" ]
    aws_ ["dynamodb", "wait", "table-exists", "--table-name", name]

  echo "IAM roles..."
  lambdaRole <- ensureRole name "lambda.amazonaws.com" $ policy
    [ stmt ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Scan"] [tableArn]
    , stmt ["ses:SendEmail"] ["arn:aws:ses:" <> region <> ":" <> acct <> ":identity/*"]
    , stmt ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        ["arn:aws:logs:" <> region <> ":" <> acct <> ":log-group:/aws/lambda/" <> name <> ":*"]
    ]
  schedulerRole <- ensureRole (name <> "-scheduler") "scheduler.amazonaws.com" $ policy
    [stmt ["lambda:InvokeFunction"] [functionArn]]

  -- Keep existing tokens so pingers keep working; add one per new heartbeat check.
  checks <- readChecks
  haveFunction <- awsOk ["lambda", "get-function", "--function-name", name]
  existing <- if haveFunction
    then fromMaybe KM.empty . (A.decodeStrict . T.encodeUtf8 =<<) . nonEmpty <$>
           awsText ["lambda", "get-function-configuration", "--function-name", name, "--query", "Environment.Variables.TOKENS", "--output", "text"]
    else pure KM.empty
  tokens <- fmap KM.fromList . forM [c | (c, "heartbeat") <- checks] $ \c ->
    case KM.lookup (K.fromText c) (existing :: KM.KeyMap Text) of
      Just t -> pure (K.fromText c, t)
      Nothing -> (\t -> (K.fromText c, t)) . T.strip . snd <$> procStrict "openssl" ["rand", "-hex", "24"] empty

  echo "Lambda..."
  tmp <- getTemporaryDirectory
  with (mktempdir tmp "watch") $ \dir -> do
    let zipFile = dir </> "function.zip"
        envFile = dir </> "env.json"
    procs "zip" ["-q", "-j", T.pack zipFile, "ops/watch/lambda/index.mjs", "ops/watch/checks.json"] empty
    T.writeFile envFile $ jsonText $ object
      [ "Variables" .= object
          [ "TABLE" .= name, "FROM" .= from, "TO" .= to
          , "TOKENS" .= jsonText (A.toJSON tokens) ] ]
    let common = ["--timeout", "60", "--memory-size", "256", "--environment", "file://" <> T.pack envFile]
    if haveFunction
      then do
        aws_ ["lambda", "update-function-code", "--function-name", name, "--zip-file", "fileb://" <> T.pack zipFile]
        aws_ ["lambda", "wait", "function-updated-v2", "--function-name", name]
        aws_ (["lambda", "update-function-configuration", "--function-name", name, "--role", lambdaRole] <> common)
      else
        -- A new role takes a few seconds to become assumable by Lambda.
        retrying 10 $ awsOk (["lambda", "create-function", "--function-name", name, "--runtime", "nodejs22.x"
          , "--handler", "index.handler", "--role", lambdaRole, "--zip-file", "fileb://" <> T.pack zipFile] <> common)
    aws_ ["lambda", "wait", "function-updated-v2", "--function-name", name]

  haveUrl <- awsOk ["lambda", "get-function-url-config", "--function-name", name]
  unless haveUrl $ aws_ ["lambda", "create-function-url-config", "--function-name", name, "--auth-type", "NONE"]
  url <- T.dropWhileEnd (== '/') <$> awsText ["lambda", "get-function-url-config", "--function-name", name, "--query", "FunctionUrl", "--output", "text"]
  -- Public URLs need both permissions; requests are authorised by check token.
  void $ awsOk ["lambda", "add-permission", "--function-name", name, "--statement-id", "url-public"
    , "--action", "lambda:InvokeFunctionUrl", "--principal", "*", "--function-url-auth-type", "NONE"]
  void $ awsOk ["lambda", "add-permission", "--function-name", name, "--statement-id", "url-public-invoke"
    , "--action", "lambda:InvokeFunction", "--principal", "*", "--invoked-via-function-url"]

  echo "Schedules..."
  schedule (name <> "-sweep") "rate(5 minutes)" "UTC" "{\"task\":\"sweep\"}" functionArn schedulerRole
  schedule (name <> "-digest") "cron(0 9 ? * MON *)" "America/Chicago" "{\"task\":\"digest\"}" functionArn schedulerRole

  echo "Datum Secret birdhaus-db-watch..."
  (found, _, _) <- procStrictWithErr "datumctl" ["get", "secret", "birdhaus-db-watch", "--project", project] empty
  if found == ExitSuccess
    then echo "  exists; kept (delete it and re-run to replace)."
    else do
      token <- maybe (die "No token for the postgres check") pure (KM.lookup "postgres" tokens)
      let manifest = object
            [ "apiVersion" .= ("v1" :: Text), "kind" .= ("Secret" :: Text)
            , "metadata" .= object ["name" .= ("birdhaus-db-watch" :: Text), "namespace" .= ("default" :: Text)]
            , "type" .= ("Opaque" :: Text)
            , "stringData" .= object ["WATCH_URL" .= url, "WATCH_CHECK" .= ("postgres" :: Text), "WATCH_TOKEN" .= token]
            ]
      procs "datumctl" ["create", "-f", "-", "--project", project] (select (textToLines (jsonText manifest)))

  printf ("\nWatch URL: " % s % "\n") url
  unless (verified == "True") $ do
    printf "\nSES has not verified birdhaus.store yet. Add these CNAMEs to dns/cname.yaml and apply:\n"
    forM_ dkim $ \t -> printf ("  " % s % "._domainkey  ->  " % s % ".dkim.amazonses.com.\n") t t

schedule :: Text -> Text -> Text -> Text -> Text -> Text -> IO ()
schedule sched expr tz input target role = do
  exists <- awsOk ["scheduler", "get-schedule", "--name", sched]
  aws_ [ "scheduler", if exists then "update-schedule" else "create-schedule", "--name", sched
       , "--schedule-expression", expr, "--schedule-expression-timezone", tz
       , "--flexible-time-window", "Mode=OFF"
       , "--target", jsonText (object ["Arn" .= target, "RoleArn" .= role, "Input" .= input]) ]

ensureRole :: Text -> Text -> Value -> IO Text
ensureRole role service perms = do
  exists <- awsOk ["iam", "get-role", "--role-name", role]
  unless exists $ aws_
    [ "iam", "create-role", "--role-name", role
    , "--assume-role-policy-document", jsonText (policy [object
        [ "Effect" .= ("Allow" :: Text), "Principal" .= object ["Service" .= service], "Action" .= ("sts:AssumeRole" :: Text) ]]) ]
  aws_ ["iam", "put-role-policy", "--role-name", role, "--policy-name", role, "--policy-document", jsonText perms]
  awsText ["iam", "get-role", "--role-name", role, "--query", "Role.Arn", "--output", "text"]

policy :: [Value] -> Value
policy statements = object ["Version" .= ("2012-10-17" :: Text), "Statement" .= statements]

stmt :: [Text] -> [Text] -> Value
stmt actions resources = object ["Effect" .= ("Allow" :: Text), "Action" .= actions, "Resource" .= resources]

-- (name, kind) of each check in ops/watch/checks.json.
readChecks :: IO [(Text, Text)]
readChecks = do
  raw <- BL.readFile "ops/watch/checks.json"
  case A.decode raw of
    Just (A.Array xs) -> pure (mapMaybe pair (foldr (:) [] xs))
    _ -> die "ops/watch/checks.json is not a JSON array"
  where
    pair (A.Object o) = (,) <$> str "name" o <*> str "kind" o
    pair _ = Nothing
    str k o = case KM.lookup k o of
      Just (A.String t) -> Just t
      _ -> Nothing

-- ---------------------------------------------------------------- operate

status :: IO ()
status = do
  out <- awsText ["dynamodb", "scan", "--table-name", name, "--output", "json"]
  let items = case A.decodeStrict (T.encodeUtf8 out) of
        Just (A.Object o) | Just (A.Array xs) <- KM.lookup "Items" o -> foldr (:) [] xs
        _ -> []
  when (null items) $ echo "No state yet (the first sweep runs within 5 minutes of deploy)."
  forM_ items $ \item -> case item of
    A.Object o
      | Just (A.Object c) <- KM.lookup "check" o, Just (A.String check) <- KM.lookup "S" c
      , Just (A.Object st) <- KM.lookup "state" o, Just (A.String js) <- KM.lookup "S" st ->
          printf (s % ": " % s % "\n") check js
    _ -> pure ()

invoke :: Text -> IO ()
invoke payload = do
  tmp <- getTemporaryDirectory
  with (mktempdir tmp "watch") $ \dir -> do
    let out = dir </> "out.json"
    aws_ ["lambda", "invoke", "--function-name", name, "--cli-binary-format", "raw-in-base64-out", "--payload", payload, T.pack out]
    T.readFile out >>= T.putStrLn

-- ---------------------------------------------------------------- AWS plumbing

runAws :: [Text] -> IO (ExitCode, Text, Text)
runAws args = do
  (code, out, err) <- P.readProcessWithExitCode "aws" (map T.unpack (["--region", region] <> args)) ""
  pure (code, T.pack out, T.pack err)

-- Stdout of a call; dies with aws's message on failure.
awsText :: [Text] -> IO Text
awsText args = do
  (code, out, err) <- runAws args
  when (code /= ExitSuccess) $ die ("aws " <> T.unwords (take 2 args) <> " failed: " <> T.strip err)
  pure (T.strip out)

aws_ :: [Text] -> IO ()
aws_ = void . awsText

awsOk :: [Text] -> IO Bool
awsOk args = (\(code, _, _) -> code == ExitSuccess) <$> runAws args

retrying :: Int -> IO Bool -> IO ()
retrying 0 _ = die "Gave up waiting for AWS"
retrying n act = do
  ok <- act
  unless ok $ threadDelay 3000000 >> retrying (n - 1) act

jsonText :: A.ToJSON a => a -> Text
jsonText = T.decodeUtf8 . BL.toStrict . A.encode

nonEmpty :: Text -> Maybe Text
nonEmpty t = if T.null t || t == "None" then Nothing else Just t
