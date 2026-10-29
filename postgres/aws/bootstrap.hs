#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson ])"
#! nix-shell -p awscli2

-- AWS side of the S3-backed Postgres design (docs/design/postgres-s3.md).
-- Uses whatever AWS credentials the environment provides (AWS_PROFILE, SSO);
-- datumctl must be on PATH for the commands that touch Datum secrets.
--
--   ./bootstrap.hs bucket
--   ./bootstrap.hs deployment NAME DATUM_PROJECT
--   ./bootstrap.hs rotate NAME DATUM_PROJECT
--   ./bootstrap.hs destroy NAME
--   ./bootstrap.hs destroy-bucket
--   ./bootstrap.hs test-isolation
--
-- The bucket is --bucket, else $BUCKET, else birdhaus-pg-<account id>-<region
-- code> (for example birdhaus-pg-123456789012-use1) from the active account.
--
-- Isolation model: one shared bucket, one prefix per deployment, one IAM user
-- per deployment tagged deployment=NAME. A single shared managed policy grants
-- access to s3://BUCKET/${aws:PrincipalTag/deployment}/* only, so there is no
-- per-deployment policy to write, and a user cannot reach another deployment's
-- prefix, list it, or change its own tag (it has no IAM permissions).

{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, finally, try)
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (getTemporaryDirectory)
import System.Environment (getEnvironment)
import qualified System.Process as P
import Turtle hiding (FilePath, (</>))

data Ctx = Ctx {bucket :: Text, region :: Text}

data Cmd
  = Bucket
  | Deployment Text Text
  | Rotate Text Text
  | Destroy Text
  | DestroyBucket
  | TestIsolation

policyName, iamPath :: Text
policyName = "birdhaus-pg-deployment"
iamPath = "/birdhaus-pg/"

userName :: Text -> Text
userName n = "birdhaus-pg-" <> n

-- The IAM policy variable AWS resolves per request from the caller's tag.
tagVar :: Text
tagVar = "${aws:PrincipalTag/deployment}"

main :: IO ()
main = do
  (mBucket, reg, cmd) <-
    options "Provision S3 storage and per-deployment IAM for Postgres backups" $
      (,,)
        <$> optional (optText "bucket" 'b' "Bucket name (default: $BUCKET, else birdhaus-pg-<account>-<region code>)")
        <*> (optText "region" 'r' "AWS region (default: us-east-1)" <|> pure "us-east-1")
        <*> cmdParser
  fromEnv <- need "BUCKET"
  b <- case mBucket <|> fromEnv of
    Just named -> pure named
    Nothing -> defaultBucket reg
  let c = Ctx b reg
  case cmd of
    Bucket -> cmdBucket c
    Deployment n p -> cmdDeployment c n p
    Rotate n p -> cmdRotate c n p
    Destroy n -> cmdDestroy c n
    DestroyBucket -> cmdDestroyBucket c
    TestIsolation -> cmdTestIsolation c

-- birdhaus-pg-<account id>-<short region>, e.g. birdhaus-pg-123456789012-use1.
-- Bucket names are global, so the account id keeps the default unique per account.
defaultBucket :: Text -> IO Text
defaultBucket reg = do
  acct <- awsText (Ctx "" reg) ["sts", "get-caller-identity", "--query", "Account", "--output", "text"]
  pure ("birdhaus-pg-" <> acct <> "-" <> regionCode reg)

-- us-east-1 -> use1, eu-central-1 -> euc1, ap-southeast-2 -> apse2. Regions that
-- do not fit the pattern (such as us-gov-west-1) keep their full name.
regionCode :: Text -> Text
regionCode reg = case T.splitOn "-" reg of
  [geo, dir, n] | Just d <- lookup dir directions -> geo <> d <> n
  _ -> reg
  where
    directions =
      [ ("north", "n"), ("south", "s"), ("east", "e"), ("west", "w"), ("central", "c")
      , ("northeast", "ne"), ("northwest", "nw"), ("southeast", "se"), ("southwest", "sw") ]

cmdParser :: Parser Cmd
cmdParser =
  subcommand "bucket" "Create or update the bucket and the shared policy" (pure Bucket)
    <|> subcommand "deployment" "Create a deployment's IAM user and Datum secret"
      (Deployment <$> argText "name" "Deployment name" <*> argText "project" "Datum project")
    <|> subcommand "rotate" "Replace a deployment's access key and Datum secret"
      (Rotate <$> argText "name" "Deployment name" <*> argText "project" "Datum project")
    <|> subcommand "destroy" "Delete a deployment's IAM user (its data is kept)"
      (Destroy <$> argText "name" "Deployment name")
    <|> subcommand "destroy-bucket" "Delete the bucket, every object version and the shared policy"
      (pure DestroyBucket)
    <|> subcommand "test-isolation" "Prove deployments cannot see each other's data" (pure TestIsolation)

-- Deployment names double as S3 prefixes and IAM user names.
checkName :: Text -> IO ()
checkName n = unless valid $ die ("Bad deployment name '" <> n <> "' (want ^[a-z0-9][a-z0-9-]{1,40}$)")
  where
    valid = T.length n >= 2 && T.length n <= 41 && T.all ok n && edge (T.head n)
    edge ch = isLower ch || isNum ch
    ok ch = edge ch || ch == '-'
    isLower ch = ch >= 'a' && ch <= 'z'
    isNum ch = ch >= '0' && ch <= '9'

-- ---------------------------------------------------------------- AWS plumbing

newtype Creds = Creds (String, String)

-- Runs the aws CLI. With creds it acts as that IAM user instead of the admin
-- profile, which is how the isolation test impersonates a deployment.
runAws :: Ctx -> Maybe Creds -> [Text] -> IO (ExitCode, Text, Text)
runAws c creds args = do
  base <- getEnvironment
  let strip = ["AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"]
      e = case creds of
        Nothing -> base
        Just (Creds (k, s)) ->
          [kv | kv@(n, _) <- base, n `notElem` strip]
            <> [("AWS_ACCESS_KEY_ID", k), ("AWS_SECRET_ACCESS_KEY", s)]
      cp = (P.proc "aws" (map T.unpack (["--region", region c] <> args))) {P.env = Just e}
  (code, out, err) <- P.readCreateProcessWithExitCode cp ""
  pure (code, T.pack out, T.pack err)

-- Stdout of an admin call; dies with aws's message on failure.
awsText :: Ctx -> [Text] -> IO Text
awsText c args = do
  (code, out, err) <- runAws c Nothing args
  when (code /= ExitSuccess) $
    die ("aws " <> T.unwords (take 2 args) <> " failed: " <> T.strip err)
  pure (T.strip out)

aws_ :: Ctx -> [Text] -> IO ()
aws_ c = void . awsText c

awsOk :: Ctx -> [Text] -> IO Bool
awsOk c args = (\(code, _, _) -> code == ExitSuccess) <$> runAws c Nothing args

jsonText :: Value -> Text
jsonText = T.decodeUtf8 . BL.toStrict . encode

policyArn :: Ctx -> IO Text
policyArn c = do
  acct <- awsText c ["sts", "get-caller-identity", "--query", "Account", "--output", "text"]
  pure ("arn:aws:iam::" <> acct <> ":policy" <> iamPath <> policyName)

-- ------------------------------------------------------------------ documents

policyDocument :: Ctx -> Value
policyDocument c =
  object
    [ "Version" .= ("2012-10-17" :: Text)
    , "Statement"
        .= [ object
               [ "Sid" .= ("ListOwnPrefix" :: Text)
               , "Effect" .= ("Allow" :: Text)
               , "Action" .= (["s3:ListBucket", "s3:ListBucketMultipartUploads"] :: [Text])
               , "Resource" .= bucketArn
               , "Condition" .= object ["StringLike" .= object ["s3:prefix" .= [tagVar <> "/*"]]]
               ]
           , object
               [ "Sid" .= ("BucketLocation" :: Text)
               , "Effect" .= ("Allow" :: Text)
               , "Action" .= ("s3:GetBucketLocation" :: Text)
               , "Resource" .= bucketArn
               ]
           , object
               [ "Sid" .= ("OwnObjects" :: Text)
               , "Effect" .= ("Allow" :: Text)
               , "Action"
                   .= ( [ "s3:GetObject", "s3:PutObject", "s3:DeleteObject"
                        , "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts" ] :: [Text] )
               , "Resource" .= (bucketArn <> "/" <> tagVar <> "/*")
               ]
           , object
               [ "Sid" .= ("DenyWithoutDeploymentTag" :: Text)
               , "Effect" .= ("Deny" :: Text)
               , "Action" .= ("s3:*" :: Text)
               , "Resource" .= ("*" :: Text)
               , "Condition" .= object ["Null" .= object ["aws:PrincipalTag/deployment" .= ("true" :: Text)]]
               ]
           ]
    ]
  where
    bucketArn = "arn:aws:s3:::" <> bucket c

bucketPolicy :: Ctx -> Value
bucketPolicy c =
  object
    [ "Version" .= ("2012-10-17" :: Text)
    , "Statement"
        .= [ object
               [ "Sid" .= ("DenyInsecureTransport" :: Text)
               , "Effect" .= ("Deny" :: Text)
               , "Principal" .= ("*" :: Text)
               , "Action" .= ("s3:*" :: Text)
               , "Resource" .= (["arn:aws:s3:::" <> bucket c, "arn:aws:s3:::" <> bucket c <> "/*"] :: [Text])
               , "Condition" .= object ["Bool" .= object ["aws:SecureTransport" .= ("false" :: Text)]]
               ]
           ]
    ]

lifecycle :: Value
lifecycle =
  object
    [ "Rules"
        .= [ object
               [ "ID" .= ("expire-old-versions" :: Text)
               , "Status" .= ("Enabled" :: Text)
               , "Filter" .= object []
               , "NoncurrentVersionExpiration" .= object ["NoncurrentDays" .= (14 :: Int)]
               , "AbortIncompleteMultipartUpload" .= object ["DaysAfterInitiation" .= (7 :: Int)]
               , "Expiration" .= object ["ExpiredObjectDeleteMarker" .= True]
               ]
           ]
    ]

encryption :: Value
encryption =
  object
    [ "Rules"
        .= [ object
               [ "ApplyServerSideEncryptionByDefault" .= object ["SSEAlgorithm" .= ("AES256" :: Text)]
               , "BucketKeyEnabled" .= True
               ]
           ]
    ]

-- ------------------------------------------------------------------- commands

say :: Text -> IO ()
say = T.putStrLn

cmdBucket :: Ctx -> IO ()
cmdBucket c = do
  let b = bucket c
  exists <- awsOk c ["s3api", "head-bucket", "--bucket", b]
  if exists
    then say ("bucket " <> b <> " exists; reapplying settings")
    else do
      -- us-east-1 takes no LocationConstraint.
      aws_ c $ ["s3api", "create-bucket", "--bucket", b]
        <> (if region c == "us-east-1" then [] else ["--create-bucket-configuration", "LocationConstraint=" <> region c])
      say ("created bucket " <> b)
  aws_ c ["s3api", "put-public-access-block", "--bucket", b, "--public-access-block-configuration"
         , "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"]
  aws_ c ["s3api", "put-bucket-ownership-controls", "--bucket", b
         , "--ownership-controls", "Rules=[{ObjectOwnership=BucketOwnerEnforced}]"]
  aws_ c ["s3api", "put-bucket-encryption", "--bucket", b, "--server-side-encryption-configuration", jsonText encryption]
  aws_ c ["s3api", "put-bucket-versioning", "--bucket", b, "--versioning-configuration", "Status=Enabled"]
  aws_ c ["s3api", "put-bucket-lifecycle-configuration", "--bucket", b, "--lifecycle-configuration", jsonText lifecycle]
  aws_ c ["s3api", "put-bucket-policy", "--bucket", b, "--policy", jsonText (bucketPolicy c)]
  -- Shared managed policy: create, or add a new default version and prune old ones.
  arn <- policyArn c
  have <- awsOk c ["iam", "get-policy", "--policy-arn", arn]
  if have
    then do
      olds <- T.words <$> awsText c
        ["iam", "list-policy-versions", "--policy-arn", arn, "--query", "Versions[?!IsDefaultVersion].VersionId", "--output", "text"]
      forM_ olds $ \v -> aws_ c ["iam", "delete-policy-version", "--policy-arn", arn, "--version-id", v]
      aws_ c ["iam", "create-policy-version", "--policy-arn", arn, "--set-as-default", "--policy-document", jsonText (policyDocument c)]
      say ("updated policy " <> arn)
    else do
      aws_ c ["iam", "create-policy", "--policy-name", policyName, "--path", iamPath, "--policy-document", jsonText (policyDocument c)]
      say ("created policy " <> arn)

-- Creates the user, tags it and attaches the shared policy. Prints nothing secret.
ensureUser :: Ctx -> Text -> IO ()
ensureUser c name = do
  let user = userName name
      tags = "Key=deployment,Value=" <> name
  exists <- awsOk c ["iam", "get-user", "--user-name", user]
  if exists
    then aws_ c ["iam", "tag-user", "--user-name", user, "--tags", tags]
    else aws_ c ["iam", "create-user", "--user-name", user, "--path", iamPath, "--tags", tags]
  arn <- policyArn c
  aws_ c ["iam", "attach-user-policy", "--user-name", user, "--policy-arn", arn]

accessKeyIds :: Ctx -> Text -> IO [Text]
accessKeyIds c user =
  T.words <$> awsText c ["iam", "list-access-keys", "--user-name", user, "--query", "AccessKeyMetadata[].AccessKeyId", "--output", "text"]

newKey :: Ctx -> Text -> IO (Text, Text)
newKey c user = do
  out <- awsText c ["iam", "create-access-key", "--user-name", user, "--query", "AccessKey.[AccessKeyId,SecretAccessKey]", "--output", "text"]
  case T.words out of
    [k, s] -> pure (k, s)
    _ -> die "Unexpected output from create-access-key"

-- The key goes from the aws response straight into datumctl's stdin; it never
-- touches disk or a command line. `create` rather than `apply`, because apply
-- copies the secret into a plaintext last-applied-configuration annotation.
makeSecret :: Ctx -> Text -> Text -> (Text, Text) -> IO ()
makeSecret c name project (k, s) =
  procs "datumctl" ["create", "-f", "-", "--project", project] (select (textToLines manifest))
  where
    manifest =
      jsonText $ object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("Secret" :: Text)
        , "metadata" .= object ["name" .= (name <> "-aws"), "namespace" .= ("default" :: Text)]
        , "type" .= ("Opaque" :: Text)
        , "stringData"
            .= object
              [ "AWS_ACCESS_KEY_ID" .= k
              , "AWS_SECRET_ACCESS_KEY" .= s
              , "AWS_REGION" .= region c
              , "WALG_S3_PREFIX" .= ("s3://" <> bucket c <> "/" <> name)
              ]
        ]

cmdDeployment :: Ctx -> Text -> Text -> IO ()
cmdDeployment c name project = do
  checkName name
  ensureUser c name
  let user = userName name
  existing <- accessKeyIds c user
  unless (null existing) $ die (user <> " already has an access key; use 'rotate' to replace it")
  key <- newKey c user
  makeSecret c name project key
  printf ("deployment " % s % " ready: s3://" % s % "/" % s % "/ (secret " % s % "-aws)\n") name (bucket c) name name

cmdRotate :: Ctx -> Text -> Text -> IO ()
cmdRotate c name project = do
  checkName name
  let user = userName name
  old <- accessKeyIds c user
  -- Create the new key first so a failure never leaves the deployment keyless.
  new <- newKey c user
  (found, _) <- procStrict "datumctl" ["get", "secret", name <> "-aws", "--project", project] empty
  when (found == ExitSuccess) $
    procs "datumctl" ["delete", "secret", name <> "-aws", "--project", project] empty
  makeSecret c name project new
  forM_ old $ \k -> aws_ c ["iam", "delete-access-key", "--user-name", user, "--access-key-id", k]
  say "rotated; restart the workload to pick up the new secret"

-- Removes the IAM user and its keys. Data under s3://BUCKET/NAME/ is kept on purpose.
cmdDestroy :: Ctx -> Text -> IO ()
cmdDestroy c name = do
  checkName name
  let user = userName name
  exists <- awsOk c ["iam", "get-user", "--user-name", user]
  if not exists
    then say ("no " <> user <> "; nothing to delete")
    else do
      keys <- accessKeyIds c user
      forM_ keys $ \k -> aws_ c ["iam", "delete-access-key", "--user-name", user, "--access-key-id", k]
      arn <- policyArn c
      void $ awsOk c ["iam", "detach-user-policy", "--user-name", user, "--policy-arn", arn]
      aws_ c ["iam", "delete-user", "--user-name", user]
      say ("deleted " <> user <> " (data under s3://" <> (bucket c) <> "/" <> name <> "/ kept)")

-- Versioned buckets need every version and delete marker removed before the
-- bucket can go. WAL-G's keys have no spaces, so the text query is enough.
purgeBucket :: Ctx -> IO ()
purgeBucket c = go
  where
    go = do
      out <- awsText c
        [ "s3api", "list-object-versions", "--bucket", bucket c
        , "--query", "[Versions,DeleteMarkers][][].[Key,VersionId]", "--output", "text" ]
      let versions = [pair | l <- T.lines out, Just pair <- [parseLine l]]
          parseLine l = case T.words l of
            [k, v] | v /= "None" -> Just (k, v)
            _ -> Nothing
      unless (null versions) $ do
        let batch = take 1000 versions
        tmp <- getTemporaryDirectory
        with (mktempfile tmp "purge") $ \path -> do
          T.writeFile path $ jsonText $ object
            [ "Objects" .= [object ["Key" .= k, "VersionId" .= v] | (k, v) <- batch]
            , "Quiet" .= True
            ]
          aws_ c ["s3api", "delete-objects", "--bucket", bucket c, "--delete", "file://" <> T.pack path]
        printf ("  deleted " % d % " object versions\n") (length batch)
        go

-- Deletes the bucket and, once no user uses it, the shared policy.
cmdDestroyBucket :: Ctx -> IO ()
cmdDestroyBucket c = do
  let b = bucket c
  exists <- awsOk c ["s3api", "head-bucket", "--bucket", b]
  if exists
    then do
      say ("emptying bucket " <> b <> "...")
      purgeBucket c
      aws_ c ["s3api", "delete-bucket", "--bucket", b]
      say ("deleted bucket " <> b)
    else say ("no bucket " <> b)
  arn <- policyArn c
  have <- awsOk c ["iam", "get-policy", "--policy-arn", arn]
  when have $ do
    attached <- T.words <$> awsText c
      [ "iam", "list-entities-for-policy", "--policy-arn", arn
      , "--query", "[length(PolicyUsers),length(PolicyGroups),length(PolicyRoles)]", "--output", "text" ]
    if all (== "0") attached
      then do
        -- IAM refuses to delete a policy that still has non-default versions.
        versions <- T.words <$> awsText c
          ["iam", "list-policy-versions", "--policy-arn", arn, "--query", "Versions[?!IsDefaultVersion].VersionId", "--output", "text"]
        forM_ versions $ \v -> aws_ c ["iam", "delete-policy-version", "--policy-arn", arn, "--version-id", v]
        aws_ c ["iam", "delete-policy", "--policy-arn", arn]
        say ("deleted policy " <> arn)
      else say ("kept policy " <> arn <> "; it is still attached")

-- Deletes every version and delete marker under a prefix (the bucket is versioned).
purgePrefix :: Ctx -> Text -> IO ()
purgePrefix c prefix = do
  out <- awsText c
    [ "s3api", "list-object-versions", "--bucket", bucket c, "--prefix", prefix <> "/"
    , "--query", "[Versions,DeleteMarkers][][].[Key,VersionId]", "--output", "text" ]
  forM_ (T.lines out) $ \l -> case T.words l of
    [k, v] | v /= "None" ->
      aws_ c ["s3api", "delete-object", "--bucket", bucket c, "--key", k, "--version-id", v]
    _ -> pure ()

-- Proves isolation with throwaway deployments and their real credentials, then
-- deletes everything it created.
cmdTestIsolation :: Ctx -> IO ()
cmdTestIsolation c = do
  suffix <- T.pack . show . (round :: Double -> Integer) . realToFrac <$> getPOSIXTime
  let a = "iso-a-" <> suffix
      b = "iso-b-" <> suffix
      a2 = "iso-a-" <> suffix <> "-2" -- shares a's name as a prefix
      u = "iso-c-" <> suffix -- policy attached, but no deployment tag
      bkt = bucket c
  failed <- newIORef False

  let cleanup = do
        forM_ [a, b, a2, u] $ \p -> ignore (purgePrefix c p)
        forM_ [a, b, a2, u] $ \n -> ignore (cmdDestroy c n)
      ignore act = void (try act :: IO (Either SomeException ()))

  (`finally` cleanup) $ do
    forM_ [a, b, a2] (ensureUser c)
    aws_ c ["iam", "create-user", "--user-name", userName u, "--path", iamPath]
    arn <- policyArn c
    aws_ c ["iam", "attach-user-policy", "--user-name", userName u, "--policy-arn", arn]
    ca <- Creds <$> keyPair a
    cu <- Creds <$> keyPair u

    -- Seed other deployments' objects with the admin credentials.
    aws_ c ["s3api", "put-object", "--bucket", bkt, "--key", b <> "/base/obj"]
    aws_ c ["s3api", "put-object", "--bucket", bkt, "--key", a2 <> "/base/obj"]

    say "waiting for IAM propagation..."
    let waitFor n = do
          ok <- allowed ca ["s3api", "put-object", "--bucket", bkt, "--key", a <> "/probe"]
          unless (ok || n == (0 :: Int)) $ threadDelay 2000000 >> waitFor (n - 1)
    waitFor 30

    let expectOk d who args = do
          ok <- allowed who args
          if ok then T.putStrLn ("  ok    " <> d) else T.putStrLn ("  FAIL  " <> d <> " (expected allowed)") >> modifyIORef' failed (const True)
        expectDeny d who args = do
          ok <- allowed who args
          if ok then T.putStrLn ("  FAIL  " <> d <> " (expected denied)") >> modifyIORef' failed (const True) else T.putStrLn ("  ok    " <> d <> " denied")
        getObj k = ["s3api", "get-object", "--bucket", bkt, "--key", k, "/dev/null"]
        putObj k = ["s3api", "put-object", "--bucket", bkt, "--key", k]
        listPrefix p = ["s3api", "list-objects-v2", "--bucket", bkt, "--prefix", p]

    say "own prefix:"
    expectOk "put own object" ca (putObj (a <> "/wal/1"))
    expectOk "get own object" ca (getObj (a <> "/wal/1"))
    expectOk "list own prefix" ca (listPrefix (a <> "/"))
    expectOk "delete own object" ca ["s3api", "delete-object", "--bucket", bkt, "--key", a <> "/wal/1"]

    say "another deployment's prefix:"
    expectDeny "get b object" ca (getObj (b <> "/base/obj"))
    expectDeny "put into b" ca (putObj (b <> "/wal/x"))
    expectDeny "delete b object" ca ["s3api", "delete-object", "--bucket", bkt, "--key", b <> "/base/obj"]
    expectDeny "list b prefix" ca (listPrefix (b <> "/"))
    expectDeny "list whole bucket" ca ["s3api", "list-objects-v2", "--bucket", bkt]
    expectDeny "list empty prefix" ca (listPrefix "")

    say "name-prefix confusion (a vs a-2):"
    expectDeny "get a-2 object" ca (getObj (a2 <> "/base/obj"))
    expectDeny "list a-2 prefix" ca (listPrefix (a2 <> "/"))
    expectDeny "list a without slash" ca (listPrefix a)

    say "no tag:"
    expectDeny "untagged user put" cu (putObj (u <> "/x"))
    expectDeny "untagged user list" cu (listPrefix (u <> "/"))

    say "self-service escalation:"
    expectDeny "tag itself" ca ["iam", "tag-user", "--user-name", userName a, "--tags", "Key=deployment,Value=" <> b]
    expectDeny "attach admin policy" ca ["iam", "attach-user-policy", "--user-name", userName a, "--policy-arn", "arn:aws:iam::aws:policy/AdministratorAccess"]
    expectDeny "change bucket policy" ca ["s3api", "put-bucket-policy", "--bucket", bkt, "--policy", "{}"]

    say "transport:"
    expectDeny "plain HTTP" ca (listPrefix (a <> "/") <> ["--endpoint-url", "http://s3." <> region c <> ".amazonaws.com"])

  bad <- readIORef failed
  if bad
    then say "ISOLATION CHECKS FAILED" >> exit (ExitFailure 1)
    else say "ALL ISOLATION CHECKS PASSED"
  where
    allowed who args = (\(code, _, _) -> code == ExitSuccess) <$> runAws c (Just who) args
    keyPair n = do
      (k, s') <- newKey c (userName n)
      pure (T.unpack k, T.unpack s')
