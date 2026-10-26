#!/usr/bin/env bash
# AWS side of the S3-backed Postgres design (docs/design/postgres-s3.md).
#
#   AWS_PROFILE=<admin profile> BUCKET=<name> ./bootstrap.sh bucket
#   AWS_PROFILE=... BUCKET=... ./bootstrap.sh deployment <name> <datum-project>
#   AWS_PROFILE=... BUCKET=... ./bootstrap.sh rotate <name> <datum-project>
#   AWS_PROFILE=... BUCKET=... ./bootstrap.sh destroy <name>
#   AWS_PROFILE=... BUCKET=... ./bootstrap.sh test-isolation
#
# Isolation model: one shared bucket, one prefix per deployment, one IAM user per
# deployment tagged deployment=<name>. A single shared managed policy grants access
# to s3://BUCKET/${aws:PrincipalTag/deployment}/* only, so there is no per-deployment
# policy to write, and a user cannot reach another deployment's prefix, list it, or
# change its own tag (it has no IAM permissions).
set -euo pipefail

: "${BUCKET:?set BUCKET}"
REGION="${AWS_REGION:-us-east-1}"
POLICY_NAME="birdhaus-pg-deployment"
IAM_PATH="/birdhaus-pg/"
NAME_RE='^[a-z0-9][a-z0-9-]{1,40}$'

aws_() { aws --region "$REGION" "$@"; }
account() { aws_ sts get-caller-identity --query Account --output text; }
policy_arn() { echo "arn:aws:iam::$(account):policy${IAM_PATH}${POLICY_NAME}"; }
user_name() { echo "birdhaus-pg-$1"; }
check_name() { [[ "$1" =~ $NAME_RE ]] || { echo "bad deployment name '$1' (want $NAME_RE)" >&2; exit 2; }; }

# The shared deployment policy. ${aws:PrincipalTag/deployment} is an IAM policy
# variable, resolved by AWS at request time, not by this shell.
policy_document() {
  cat <<'JSON' | sed "s/__BUCKET__/$BUCKET/g"
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ListOwnPrefix", "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": "arn:aws:s3:::__BUCKET__",
      "Condition": { "StringLike": { "s3:prefix": ["${aws:PrincipalTag/deployment}/*"] } } },
    { "Sid": "BucketLocation", "Effect": "Allow",
      "Action": "s3:GetBucketLocation",
      "Resource": "arn:aws:s3:::__BUCKET__" },
    { "Sid": "OwnObjects", "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject",
                 "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": "arn:aws:s3:::__BUCKET__/${aws:PrincipalTag/deployment}/*" },
    { "Sid": "DenyWithoutDeploymentTag", "Effect": "Deny",
      "Action": "s3:*", "Resource": "*",
      "Condition": { "Null": { "aws:PrincipalTag/deployment": "true" } } }
  ]
}
JSON
}

cmd_bucket() {
  if aws_ s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "bucket $BUCKET exists; reapplying settings"
  else
    # us-east-1 takes no LocationConstraint.
    if [ "$REGION" = us-east-1 ]; then aws_ s3api create-bucket --bucket "$BUCKET" >/dev/null
    else aws_ s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null; fi
    echo "created bucket $BUCKET"
  fi
  aws_ s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws_ s3api put-bucket-ownership-controls --bucket "$BUCKET" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  aws_ s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
  aws_ s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
  aws_ s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
    "Rules":[{"ID":"expire-old-versions","Status":"Enabled","Filter":{},
      "NoncurrentVersionExpiration":{"NoncurrentDays":14},
      "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7},
      "Expiration":{"ExpiredObjectDeleteMarker":true}}]}'
  aws_ s3api put-bucket-policy --bucket "$BUCKET" --policy "$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*",
 "Action":"s3:*","Resource":["arn:aws:s3:::$BUCKET","arn:aws:s3:::$BUCKET/*"],
 "Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
JSON
)"
  # Shared managed policy: create, or add a new default version and prune old ones.
  local arn; arn="$(policy_arn)"
  if aws_ iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    for v in $(aws_ iam list-policy-versions --policy-arn "$arn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
      aws_ iam delete-policy-version --policy-arn "$arn" --version-id "$v"
    done
    aws_ iam create-policy-version --policy-arn "$arn" --set-as-default --policy-document "$(policy_document)" >/dev/null
    echo "updated policy $arn"
  else
    aws_ iam create-policy --policy-name "$POLICY_NAME" --path "$IAM_PATH" --policy-document "$(policy_document)" >/dev/null
    echo "created policy $arn"
  fi
}

# Creates the user, tags it, attaches the shared policy. Prints nothing secret.
ensure_user() {
  local name="$1" user; user="$(user_name "$name")"
  if ! aws_ iam get-user --user-name "$user" >/dev/null 2>&1; then
    aws_ iam create-user --user-name "$user" --path "$IAM_PATH" --tags "Key=deployment,Value=$name" >/dev/null
  else
    aws_ iam tag-user --user-name "$user" --tags "Key=deployment,Value=$name"
  fi
  aws_ iam attach-user-policy --user-name "$user" --policy-arn "$(policy_arn)"
}

# Writes the Datum secret straight from the key response; the key never touches disk.
# Uses `create` (not `apply`) so no last-applied-configuration annotation copies the key.
make_secret() {
  local name="$1" project="$2" key_json="$3"
  python3 - "$name" "$BUCKET" "$REGION" "$key_json" <<'PY' | datumctl create -f - --project "$project"
import json, sys
name, bucket, region, key = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4])["AccessKey"]
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": f"{name}-aws", "namespace": "default"},
  "type": "Opaque", "stringData": {
    "AWS_ACCESS_KEY_ID": key["AccessKeyId"], "AWS_SECRET_ACCESS_KEY": key["SecretAccessKey"],
    "AWS_REGION": region, "WALG_S3_PREFIX": f"s3://{bucket}/{name}"}}))
PY
}

cmd_deployment() {
  local name="$1" project="$2"; check_name "$name"
  ensure_user "$name"
  local user; user="$(user_name "$name")"
  if [ -n "$(aws_ iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text)" ]; then
    echo "$user already has an access key; use 'rotate' to replace it" >&2; exit 1
  fi
  make_secret "$name" "$project" "$(aws_ iam create-access-key --user-name "$user")"
  echo "deployment $name ready: s3://$BUCKET/$name/ (secret ${name}-aws)"
}

cmd_rotate() {
  local name="$1" project="$2"; check_name "$name"
  local user; user="$(user_name "$name")"
  local old; old="$(aws_ iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text)"
  # Create the new key first so a failure never leaves the deployment without one.
  local new; new="$(aws_ iam create-access-key --user-name "$user")"
  datumctl delete secret "${name}-aws" --project "$project" --ignore-not-found >/dev/null
  make_secret "$name" "$project" "$new"
  for k in $old; do aws_ iam delete-access-key --user-name "$user" --access-key-id "$k"; done
  echo "rotated; restart the workload to pick up the new secret"
}

# Removes the IAM user. The data under s3://BUCKET/<name>/ is left alone on purpose.
cmd_destroy() {
  local name="$1" user; check_name "$name"; user="$(user_name "$name")"
  for k in $(aws_ iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws_ iam delete-access-key --user-name "$user" --access-key-id "$k"
  done
  aws_ iam detach-user-policy --user-name "$user" --policy-arn "$(policy_arn)"
  aws_ iam delete-user --user-name "$user"
  echo "deleted $user (data under s3://$BUCKET/$name/ kept)"
}

# Proves isolation with throwaway users. Uses real credentials, deletes everything after.
cmd_test_isolation() {
  # Globals, not locals: the EXIT trap runs after this function returns.
  suffix="$(date +%s)"
  a="iso-a-$suffix"; b="iso-b-$suffix"; a2="iso-a-$suffix-2"; c="iso-c-$suffix"
  fail=0
  users=()
  cleanup() {
    aws_ s3 rm "s3://$BUCKET/" --recursive --exclude '*' \
      $(for p in $a $b $a2 $c; do echo --include "$p/*"; done) >/dev/null 2>&1 || true
    # Versioned bucket: remove all versions and delete markers under the test prefixes.
    for p in $a $b $a2 $c; do
      aws_ s3api list-object-versions --bucket "$BUCKET" --prefix "$p/" \
        --query '[Versions,DeleteMarkers][][].[Key,VersionId]' --output text 2>/dev/null | while read -r k v; do
        [ -n "$k" ] && [ "$k" != None ] && aws_ s3api delete-object --bucket "$BUCKET" --key "$k" --version-id "$v" >/dev/null
      done
    done
    for n in "${users[@]}" "$c"; do cmd_destroy "$n" >/dev/null 2>&1 || true; done
  }
  trap cleanup EXIT

  for n in "$a" "$b" "$a2"; do ensure_user "$n"; users+=("$n"); done
  # c: policy attached but no deployment tag.
  aws_ iam create-user --user-name "$(user_name "$c")" --path "$IAM_PATH" >/dev/null
  aws_ iam attach-user-policy --user-name "$(user_name "$c")" --policy-arn "$(policy_arn)"

  # Parallel arrays: macOS ships bash 3.2, which has no associative arrays.
  local names=("$a" "$b" "$a2" "$c") aks=() sks=() out
  for n in "${names[@]}"; do
    out="$(aws_ iam create-access-key --user-name "$(user_name "$n")")"
    aks+=("$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["AccessKey"]["AccessKeyId"])' "$out")")
    sks+=("$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["AccessKey"]["SecretAccessKey"])' "$out")")
  done
  as() { local who="$1" i; shift
    for i in 0 1 2 3; do
      if [ "${names[$i]}" = "$who" ]; then
        env -u AWS_PROFILE AWS_ACCESS_KEY_ID="${aks[$i]}" AWS_SECRET_ACCESS_KEY="${sks[$i]}" AWS_REGION="$REGION" aws "$@"
        return
      fi
    done
    return 1; }

  # Seed another deployment's objects with admin credentials.
  echo secret-b | aws_ s3 cp - "s3://$BUCKET/$b/base/obj" >/dev/null
  echo secret-a2 | aws_ s3 cp - "s3://$BUCKET/$a2/base/obj" >/dev/null

  expect_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "  ok    $d"; else echo "  FAIL  $d (expected allowed)"; fail=1; fi; }
  expect_deny() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "  FAIL  $d (expected denied)"; fail=1; else echo "  ok    $d denied"; fi; }

  echo "waiting for IAM propagation..."
  for i in $(seq 1 30); do
    echo hi | as "$a" s3 cp - "s3://$BUCKET/$a/probe" >/dev/null 2>&1 && break; sleep 2
  done

  echo "own prefix:"
  expect_ok   "put own object"   as "$a" s3api put-object --bucket "$BUCKET" --key "$a/wal/1"
  expect_ok   "get own object"   as "$a" s3api get-object --bucket "$BUCKET" --key "$a/wal/1" /dev/null
  expect_ok   "list own prefix"  as "$a" s3api list-objects-v2 --bucket "$BUCKET" --prefix "$a/"
  expect_ok   "delete own object" as "$a" s3api delete-object --bucket "$BUCKET" --key "$a/wal/1"

  echo "another deployment's prefix:"
  expect_deny "get b object"        as "$a" s3api get-object --bucket "$BUCKET" --key "$b/base/obj" /dev/null
  expect_deny "put into b"          as "$a" s3api put-object --bucket "$BUCKET" --key "$b/wal/x"
  expect_deny "delete b object"     as "$a" s3api delete-object --bucket "$BUCKET" --key "$b/base/obj"
  expect_deny "list b prefix"       as "$a" s3api list-objects-v2 --bucket "$BUCKET" --prefix "$b/"
  expect_deny "list whole bucket"   as "$a" s3api list-objects-v2 --bucket "$BUCKET"
  expect_deny "list empty prefix"   as "$a" s3api list-objects-v2 --bucket "$BUCKET" --prefix ""
  echo "name-prefix confusion ('$a' vs '$a2'):"
  expect_deny "get $a2 object"      as "$a" s3api get-object --bucket "$BUCKET" --key "$a2/base/obj" /dev/null
  expect_deny "list $a2 prefix"     as "$a" s3api list-objects-v2 --bucket "$BUCKET" --prefix "$a2/"
  expect_deny "list via '$a' (no slash)" as "$a" s3api list-objects-v2 --bucket "$BUCKET" --prefix "$a"
  echo "no tag:"
  expect_deny "untagged user put"   as "$c" s3api put-object --bucket "$BUCKET" --key "$c/x"
  expect_deny "untagged user list"  as "$c" s3api list-objects-v2 --bucket "$BUCKET" --prefix "$c/"
  echo "self-service escalation:"
  expect_deny "tag itself"          as "$a" iam tag-user --user-name "$(user_name "$a")" --tags "Key=deployment,Value=$b"
  expect_deny "attach admin policy" as "$a" iam attach-user-policy --user-name "$(user_name "$a")" --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
  expect_deny "change bucket policy" as "$a" s3api put-bucket-policy --bucket "$BUCKET" --policy '{}'
  echo "transport:"
  expect_deny "plain HTTP"          as "$a" s3api list-objects-v2 --bucket "$BUCKET" --prefix "$a/" --endpoint-url "http://s3.$REGION.amazonaws.com"

  [ "$fail" = 0 ] && echo "ALL ISOLATION CHECKS PASSED" || { echo "ISOLATION CHECKS FAILED"; exit 1; }
}

case "${1:-}" in
  bucket)         cmd_bucket ;;
  deployment)     cmd_deployment "${2:?name}" "${3:?datum project}" ;;
  rotate)         cmd_rotate "${2:?name}" "${3:?datum project}" ;;
  destroy)        cmd_destroy "${2:?name}" ;;
  test-isolation) cmd_test_isolation ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
