#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson pkgs.base64-bytestring ])"
#! nix-shell -p awscli2

-- One entry point for every Birdhaus AWS resource (docs/design/aws-account.md):
-- the Postgres backup bucket and its IAM user, birdhaus-watch, and dns/ses.yaml.
--
-- Run with AWS_PROFILE set to an admin profile for the target account, and from
-- the repository root. datumctl must be on PATH.
--
--   ./ops/aws-account.hs setup --project P --alert-to EMAIL
--   ./ops/aws-account.hs copy-data --from-profile OLD --project P
--   ./ops/aws-account.hs switch --project P
--   ./ops/aws-account.hs destroy --confirm ACCOUNT_ID --project P
--
-- setup is idempotent. copy-data refuses to merge into a non-empty prefix and
-- verifies object counts and bytes. switch refuses unless the new bucket holds
-- a base backup. destroy refuses while the Datum Secrets still point at this
-- account, and requires the account ID as --confirm.

{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, unless, when)
import qualified Data.ByteString.Base64 as Base64
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import System.Directory (doesFileExist, getTemporaryDirectory)
import System.FilePath ((</>))
import qualified System.Process as P
import Turtle hiding (FilePath, (</>))

data Common = Common
  { cSession :: Maybe Text
  , cProject :: Text
  , cBucket :: Maybe Text
  , cRegion :: Text
  }

data Ctx = Ctx
  { session :: Maybe Text
  , project :: Text
  , region :: Text
  , account :: Text
  , bucket :: Text
  }

data Cmd
  = Setup Common Text
  | CopyData Common Text (Maybe Text) (Maybe Text) (Maybe Text)
  | Switch Common (Maybe Text)
  | Destroy Common Text

deployment, dbSecret :: Text
deployment = "birdhaus-db"
dbSecret = deployment <> "-aws"

deploymentUser :: Text
deploymentUser = "birdhaus-pg-" <> deployment

commonParser :: Parser Common
commonParser =
  Common
    <$> optional (optText "session" 's' "datumctl session (default: the active session)")
    <*> optText "project" 'p' "Datum Cloud project"
    <*> optional (optText "bucket" 'b' "Bucket (default: $BUCKET, else birdhaus-pg-<account>-<region code>)")
    <*> (optText "region" 'r' "AWS region (default: us-east-1)" <|> pure "us-east-1")

cmdParser :: Parser Cmd
cmdParser =
  subcommand "setup" "Create the bucket, IAM user, watcher and dns/ses.yaml"
    (Setup <$> commonParser <*> optText "alert-to" 'a' "Email address that receives alerts")
    <|> subcommand "copy-data" "Copy birdhaus-db/ from another account's bucket"
      ( CopyData
          <$> commonParser
          <*> optText "from-profile" 'f' "AWS profile for the source account"
          <*> optional (optText "from-bucket" 'F' "Source bucket (default: derived from the source account)")
          <*> optional (optText "workload" 'w' "Postgres workload holding the source (default: birdhaus-pg)")
          <*> optional (optText "instance" 'i' "Source instance (default: <workload>-default-<region>-0)")
      )
    <|> subcommand "switch" "Point Postgres at this account"
      (Switch <$> commonParser <*> optional (optText "workload" 'w' "Postgres workload (default: birdhaus-pg)"))
    <|> subcommand "destroy" "Delete every Birdhaus resource in this account"
      (Destroy <$> commonParser <*> optText "confirm" 'c' "Account ID to confirm the teardown")

main :: IO ()
main = do
  cmd <- options "Set up, migrate and tear down every Birdhaus AWS resource" cmdParser
  here <- doesFileExist "ops/watch/deploy.hs"
  unless here $ die "run from the repository root"
  let common = case cmd of
        Setup c _ -> c
        CopyData c _ _ _ _ -> c
        Switch c _ -> c
        Destroy c _ -> c
  export "DATUM_PROJECT" (cProject common)
  forM_ (cSession common) (export "DATUM_SESSION")
  acct <- awsTextAt (cRegion common) ["sts", "get-caller-identity", "--query", "Account", "--output", "text"]
  fromEnv <- need "BUCKET"
  b <- case cBucket common <|> fromEnv of
    Just named -> pure named
    Nothing -> pure ("birdhaus-pg-" <> acct <> "-" <> regionCode (cRegion common))
  let c = Ctx (cSession common) (cProject common) (cRegion common) acct b
  case cmd of
    Setup _ to -> setup c to
    CopyData _ from fromBucket wl inst -> copyData c from fromBucket wl inst
    Switch _ wl -> switchAccount c wl
    Destroy _ confirm -> destroy c confirm

-- us-east-1 -> use1, eu-central-1 -> euc1. Mirrors postgres/aws/bootstrap.hs.
regionCode :: Text -> Text
regionCode reg = case T.splitOn "-" reg of
  [geo, dir, n] | Just d <- lookup dir directions -> geo <> d <> n
  _ -> reg
  where
    directions =
      [ ("north", "n"), ("south", "s"), ("east", "e"), ("west", "w"), ("central", "c")
      , ("northeast", "ne"), ("northwest", "nw"), ("southeast", "se"), ("southwest", "sw") ]

-- ---------------------------------------------------------------- setup

setup :: Ctx -> Text -> IO ()
setup c to = do
  printf ("AWS account " % s % ", bucket " % s % "\n") (account c) (bucket c)
  say "1/4 Bucket and shared policy..."
  boot c ["bucket"]
  say "2/4 Deployment IAM user and Datum Secret..."
  haveSecret <- datumExists c dbSecret
  haveUser <- awsOk c ["iam", "get-user", "--user-name", deploymentUser]
  if haveSecret
    then say ("  Secret " <> dbSecret <> " exists; leaving it for switch to replace.")
    else
      if haveUser
        then boot c ["rotate", deployment, project c]
        else boot c ["deployment", deployment, project c]
  say "3/4 birdhaus-watch..."
  watch ["deploy", "--to", to, "--project", project c]
  say "4/4 dns/ses.yaml..."
  records <- watchText ["dkim"]
  T.writeFile sesFile (sesManifest records)
  printf ("  wrote " % s % "\n") (T.pack sesFile)
  manualSteps c to

sesFile :: FilePath
sesFile = "dns/ses.yaml"

-- The records are generated from SES; the zone name is the one in dns/.
sesManifest :: Text -> Text
sesManifest records =
  T.unlines
    [ "apiVersion: dns.networking.miloapis.com/v1alpha1"
    , "kind: DNSRecordSet"
    , "metadata:"
    , "  name: birdhaus-store-ses"
    , "  namespace: default"
    , "spec:"
    , "  dnsZoneRef:"
    , "    name: birdhaus-store-1kamnr"
    , "  recordType: CNAME"
    , "  records:"
    ]
    <> T.unlines [T.replicate 2 " " <> l | l <- T.lines records]

manualSteps :: Ctx -> Text -> IO ()
manualSteps c to = do
  let p = project c <> sessionFlag c
  echo ""
  say "Remaining manual steps:"
  say "  1. Review and apply the DNS records (changes need approval):"
  say ("       datumctl apply -f dns/ses.yaml --project " <> p)
  say ("  2. Click the SES verification link sent to " <> to <> ".")
  say "  3. Moving from another account:"
  say ("       ./ops/aws-account.hs copy-data --from-profile <old> --project " <> p)
  say ("       ./ops/aws-account.hs switch --project " <> p)
  say "  4. New deployment only:"
  say ("       ./postgres/deploy.hs --project " <> p <> " --pull-secret <secret>")

sessionFlag :: Ctx -> Text
sessionFlag c = maybe "" (\s -> " --session " <> s) (session c)

-- ---------------------------------------------------------------- copy-data

copyData :: Ctx -> Text -> Maybe Text -> Maybe Text -> Maybe Text -> IO ()
copyData c fromProfile mFromBucket mWorkload mInstance = do
  (code, out, err) <- runAws (region c) ["--profile", fromProfile, "sts", "get-caller-identity", "--query", "Account", "--output", "text"]
  when (code /= ExitSuccess) $
    die ("cannot use profile " <> fromProfile <> ": " <> T.strip err)
  let fromAccount = T.strip out
  when (fromAccount == account c) $ die "source and destination are the same AWS account"
  let fromBucket = fromMaybe ("birdhaus-pg-" <> fromAccount <> "-" <> regionCode (region c)) mFromBucket
      prefix = deployment <> "/"
      src = "s3://" <> fromBucket <> "/" <> prefix
      dst = "s3://" <> bucket c <> "/" <> prefix
      wl = fromMaybe "birdhaus-pg" mWorkload
      inst = fromMaybe (wl <> "-default-" <> region c <> "-0") mInstance

  haveBackup <- listAny (region c) ["--profile", fromProfile] fromBucket (prefix <> "basebackups_005/")
  unless haveBackup $ die ("no base backup at " <> src <> "basebackups_005/")
  destHas <- listAny (region c) [] (bucket c) prefix
  when destHas $ die ("destination " <> dst <> " is not empty; refusing to merge")

  drainSource c inst
  tmp <- getTemporaryDirectory
  with (mktempdir tmp "birdhaus-copy") $ \dir -> do
    say ("Copying " <> src <> " to a local directory...")
    procs "aws" (["--region", region c, "--profile", fromProfile, "s3", "sync", src, T.pack dir, "--only-show-errors"]) empty
    say ("Copying to " <> dst <> "...")
    procs "aws" (["--region", region c, "s3", "sync", T.pack dir, dst, "--only-show-errors"]) empty
    (sn, sb) <- statsOf (region c) ["--profile", fromProfile] fromBucket prefix
    (dn, db) <- statsOf (region c) [] (bucket c) prefix
    printf ("Source: " % d % " objects, " % d % " bytes\n") sn sb
    printf ("Destination: " % d % " objects, " % d % " bytes\n") dn db
    unless (sn == dn && sb == db) $
      die "copy mismatch; pause writers, purge the destination prefix and retry"
  say "Copy verified."

-- Closes the current WAL segment and waits until nothing is left to archive, so
-- every write up to now is in S3. Writes after this are not copied.
drainSource :: Ctx -> Text -> IO ()
drainSource c inst = do
  say "  switching WAL and waiting for the archive to drain..."
  (code, _, err) <- execScript c inst
    "gosu postgres psql -X -qAt -v ON_ERROR_STOP=1 -d postgres -c 'checkpoint' -c 'select pg_switch_wal()'"
  when (code /= ExitSuccess) $ die ("cannot reach the source Postgres: " <> T.strip err)
  let probe =
        "n=$(find /var/lib/postgresql/data/pg_wal/archive_status -name '*.ready' 2>/dev/null | wc -l); "
          <> "f=$(gosu postgres psql -X -qAt -d postgres -c \"select coalesce(last_failed_time > coalesce(last_archived_time, 'epoch'), false) from pg_stat_archiver\"); "
          <> "echo \"$n $f\""
      loop 0 = die "WAL is still waiting to be archived after 2 minutes; check pg_stat_archiver"
      loop n = do
        (ok, out, _) <- execScript c inst probe
        case T.words (lastLine out) of
          [ready, failing] | ok == ExitSuccess && ready == "0" && failing == "f" -> pure ()
          _ -> threadDelay 5000000 >> loop (n - 1)
  loop (24 :: Int)

-- ---------------------------------------------------------------- switch

switchAccount :: Ctx -> Maybe Text -> IO ()
switchAccount c mWorkload = do
  let wl = fromMaybe "birdhaus-pg" mWorkload
      inst = wl <> "-default-" <> region c <> "-0"
  haveBackup <- listAny (region c) [] (bucket c) (deployment <> "/basebackups_005/")
  unless haveBackup $
    die ("no base backup in s3://" <> bucket c <> "/" <> deployment <> "/; run copy-data first")
  to <- awsText c ["lambda", "get-function-configuration", "--function-name", "birdhaus-watch", "--query", "Environment.Variables.TO", "--output", "text"]
  when (T.null to || to == "None") $ die "birdhaus-watch is not in this account; run setup first"

  forM_ [dbSecret, "birdhaus-db-watch"] $ \s -> do
    exists <- datumExists c s
    when exists $ procs "datumctl" ["delete", "secret", s, "--project", project c] empty

  haveUser <- awsOk c ["iam", "get-user", "--user-name", deploymentUser]
  boot c (if haveUser then ["rotate", deployment, project c] else ["deployment", deployment, project c])
  -- Recreates birdhaus-db-watch with this account's URL and token.
  watch ["deploy", "--to", to, "--project", project c]

  say ("Restarting " <> wl <> "; it restores from s3://" <> bucket c <> "/" <> deployment <> "/...")
  procs "datumctl" ["compute", "restart", wl] empty
  waitForPostgres c wl inst
  counts c inst

waitForPostgres :: Ctx -> Text -> Text -> IO ()
waitForPostgres c wl inst = go (120 :: Int)
  where
    go 0 = die ("Postgres did not finish recovering; check datumctl compute logs " <> wl)
    go n = do
      (code, out, _) <- execScript c inst "gosu postgres psql -X -qAt -d postgres -c 'select pg_is_in_recovery()'"
      if code == ExitSuccess && lastLine out == "f"
        then say "  recovered"
        else threadDelay 5000000 >> go (n - 1)

counts :: Ctx -> Text -> IO ()
counts c inst = do
  bird <- execScript c inst "gosu postgres psql -X -qAt -d birdhaus -c \"select (select count(*) from orders), (select count(*) from waitlist)\""
  case bird of
    (ExitSuccess, out, _) -> say ("  birdhaus (orders|waitlist): " <> lastLine out)
    _ -> say "  birdhaus: counts unavailable"
  umami <- execScript c inst "gosu postgres psql -X -qAt -d umami -c \"select count(*) from website_event\""
  case umami of
    (ExitSuccess, out, _) -> say ("  umami website_event: " <> lastLine out)
    _ -> say "  umami: counts unavailable"

-- ---------------------------------------------------------------- destroy

destroy :: Ctx -> Text -> IO ()
destroy c confirm = do
  unless (confirm == account c) $
    die ("--confirm must be the account ID " <> account c)
  pointed <- currentPrefix c
  case bucketOf pointed of
    Just b | b == bucket c ->
      die ("the Datum Secret " <> dbSecret <> " still points at " <> fromMaybe "" pointed <> "; run switch first")
    _ -> pure ()
  say "Removing birdhaus-watch..."
  watch ["destroy"]
  haveUser <- awsOk c ["iam", "get-user", "--user-name", deploymentUser]
  when haveUser $ boot c ["destroy", deployment]
  say ("Removing bucket " <> bucket c <> "...")
  boot c ["destroy-bucket"]
  say "Account is clean."

-- WALG_S3_PREFIX of the Secret the running Postgres uses, if there is one.
-- A failed read is fatal: treating an unreachable API as "not pointed here"
-- would let destroy proceed.
currentPrefix :: Ctx -> IO (Maybe Text)
currentPrefix c = do
  (code, out, err) <- datum c ["get", "secret", dbSecret, "-o", "jsonpath={.data.WALG_S3_PREFIX}"]
  if code /= ExitSuccess
    then
      if "not found" `T.isInfixOf` T.toLower err
        then pure Nothing
        else die ("cannot read Secret " <> dbSecret <> ": " <> T.strip err)
    else do
      let val = T.strip out
      if T.null val || val == "None"
        then pure Nothing
        else case Base64.decode (T.encodeUtf8 val) of
          Left _ -> die ("cannot decode WALG_S3_PREFIX from Secret " <> dbSecret)
          Right raw -> pure (Just (T.decodeUtf8 raw))

bucketOf :: Maybe Text -> Maybe Text
bucketOf Nothing = Nothing
bucketOf (Just p) = case T.stripPrefix "s3://" p of
  Just rest -> Just (T.takeWhile (/= '/') rest)
  Nothing -> Nothing

-- ---------------------------------------------------------------- helpers

say :: Text -> IO ()
say = T.putStrLn

boot :: Ctx -> [Text] -> IO ()
boot c args =
  procs "./postgres/aws/bootstrap.hs" (["--bucket", bucket c, "--region", region c] <> args) empty

watch :: [Text] -> IO ()
watch args = procs "./ops/watch/deploy.hs" args empty

watchText :: [Text] -> IO Text
watchText args = do
  (code, out) <- procStrict "./ops/watch/deploy.hs" args empty
  when (code /= ExitSuccess) $ die ("ops/watch/deploy.hs " <> T.unwords (take 1 args) <> " failed")
  pure out

runAws :: Text -> [Text] -> IO (ExitCode, Text, Text)
runAws reg args = do
  (code, out, err) <- P.readProcessWithExitCode "aws" (map T.unpack (["--region", reg] <> args)) ""
  pure (code, T.pack out, T.pack err)

awsTextAt :: Text -> [Text] -> IO Text
awsTextAt reg args = do
  (code, out, err) <- runAws reg args
  when (code /= ExitSuccess) $
    die ("aws " <> T.unwords (take 2 args) <> " failed: " <> T.strip err)
  pure (T.strip out)

awsText :: Ctx -> [Text] -> IO Text
awsText c = awsTextAt (region c)

awsOk :: Ctx -> [Text] -> IO Bool
awsOk c args = (\(code, _, _) -> code == ExitSuccess) <$> runAws (region c) args

datum :: Ctx -> [Text] -> IO (ExitCode, Text, Text)
datum c args = do
  (code, out, err) <- P.readProcessWithExitCode "datumctl" (map T.unpack (args <> ["--project", project c])) ""
  pure (code, T.pack out, T.pack err)

-- A missing Secret is False; any other error is fatal, so a bad session or a
-- Datum outage cannot look like "nothing here yet".
datumExists :: Ctx -> Text -> IO Bool
datumExists c s = do
  (code, _, err) <- datum c ["get", "secret", s]
  if code == ExitSuccess
    then pure True
    else
      if "not found" `T.isInfixOf` T.toLower err
        then pure False
        else die ("cannot read Secret " <> s <> ": " <> T.strip err)

-- Flags cannot follow `--`, so project and session come from the environment.
execScript :: Ctx -> Text -> Text -> IO (ExitCode, Text, Text)
execScript _ inst script = do
  (code, out, err) <- P.readProcessWithExitCode "datumctl"
    ["compute", "exec", T.unpack inst, "--", "sh", "-c", T.unpack script] ""
  pure (code, T.pack out, T.pack err)

listAny :: Text -> [Text] -> Text -> Text -> IO Bool
listAny reg opts bkt prefix = do
  out <- awsTextAt reg (opts <> ["s3api", "list-objects-v2", "--bucket", bkt, "--prefix", prefix, "--max-items", "1", "--query", "Contents[].Key", "--output", "text"])
  pure (not (T.null (T.strip out)) && T.strip out /= "None")

statsOf :: Text -> [Text] -> Text -> Text -> IO (Int, Integer)
statsOf reg opts bkt prefix = do
  out <- awsTextAt reg (opts <> ["s3api", "list-objects-v2", "--bucket", bkt, "--prefix", prefix, "--query", "Contents[].Size", "--output", "text"])
  let sizes = [read (T.unpack x) :: Integer | x <- T.words out, x /= "None"]
  pure (length sizes, sum sizes)

lastLine :: Text -> Text
lastLine t = case reverse (filter (not . T.null) (map T.strip (T.lines t))) of
  x : _ -> x
  [] -> ""
