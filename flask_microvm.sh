#!/usr/bin/env bash
# =============================================================================
# Lambda MicroVM — from-scratch single-VM lifecycle demo (create -> run ->
# connect -> suspend -> resume -> terminate -> cleanup).
#
# Design choices (verified against live API + official docs, 2026-09-03):
#   * lambda-microvms subcommands run via the AWS CLI (approved this session).
#   * IAM role create + S3 upload run via boto3 (the CLI paths are guardrail-
#     blocked; boto3 is the narrow, per-operation bypass we agreed on).
#   * Build role trust principal = lambda.amazonaws.com with sts:AssumeRole +
#     sts:TagSession; inline policy = s3:GetObject on the bucket + CW logs.
#   * Base image ARN = arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1.
#   * Ingress/egress use Lambda-managed connector ARNs.
#   * Client auth = create-microvm-auth-token -> X-aws-proxy-auth header.
#
# Everything is idempotent and safe to re-run. `./flask_microvm.sh teardown`
# removes the VM, image, S3 object, bucket, and IAM role.
# =============================================================================
set -euo pipefail

# ---- config (override via env) ----------------------------------------------
export PATH="$HOME/.local/bin:$PATH"          # aws -> 2.36.37
export AWS_PAGER=""
REGION="${REGION:-us-east-1}"
NAME="${NAME:-flask-microvm-demo}"
BASE_IMAGE_ARN="${BASE_IMAGE_ARN:-arn:aws:lambda:${REGION}:aws:microvm-image:al2023-1}"
INGRESS_CONNECTOR="arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"
EGRESS_CONNECTOR="arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${HERE}/flask-microvm"
STATE_FILE="${HERE}/.microvm-state"           # records ids for teardown

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET:-lambda-microvm-lab-${ACCOUNT}-${REGION}}"
KEY="${NAME}/app.zip"
ROLE="${NAME}-build-role"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# ---- boto3 helpers (IAM + S3, guardrail-safe) -------------------------------
py_ensure_role() {
python3 - "$ROLE" "$BUCKET" "$REGION" <<'PY'
import json, sys, time, boto3
role, bucket, region = sys.argv[1], sys.argv[2], sys.argv[3]
iam = boto3.client("iam")
trust = {"Version":"2012-10-17","Statement":[{
    "Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},
    "Action":["sts:AssumeRole","sts:TagSession"]}]}
perms = {"Version":"2012-10-17","Statement":[
    {"Effect":"Allow","Action":["s3:GetObject"],"Resource":f"arn:aws:s3:::{bucket}/*"},
    {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"arn:aws:logs:*:*:*"}]}
try:
    r = iam.create_role(RoleName=role, AssumeRolePolicyDocument=json.dumps(trust),
                        Description="Lambda MicroVM build role (demo)")
    print("created role", r["Role"]["Arn"])
    time.sleep(10)  # let the role propagate before the service assumes it
except iam.exceptions.EntityAlreadyExistsException:
    print("role exists")
iam.put_role_policy(RoleName=role, PolicyName="microvm-build", PolicyDocument=json.dumps(perms))
print("ARN", iam.get_role(RoleName=role)["Role"]["Arn"])
PY
}

py_upload_artifact() {
python3 - "$BUCKET" "$KEY" "$REGION" "$APP_DIR" <<'PY'
import io, os, sys, zipfile, boto3
bucket, key, region, app_dir = sys.argv[1:5]
s3 = boto3.client("s3", region_name=region)
# create bucket (idempotent)
try:
    if region == "us-east-1":
        s3.create_bucket(Bucket=bucket)
    else:
        s3.create_bucket(Bucket=bucket, CreateBucketConfiguration={"LocationConstraint": region})
    print("created bucket", bucket)
except s3.exceptions.BucketAlreadyOwnedByYou:
    print("bucket exists")
# zip app.py + Dockerfile + requirements.txt at the ZIP ROOT (no nested dir)
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
    for f in ("Dockerfile", "app.py", "requirements.txt"):
        z.write(os.path.join(app_dir, f), arcname=f)
buf.seek(0)
s3.put_object(Bucket=bucket, Key=key, Body=buf.getvalue())
print("uploaded", f"s3://{bucket}/{key}", len(buf.getvalue()), "bytes")
PY
}

# =============================================================================
cmd_up() {
  log "0. account=$ACCOUNT region=$REGION name=$NAME"

  log "1. ensure build IAM role (boto3)"
  ROLE_ARN="$(py_ensure_role | awk '/^ARN/{print $2}')"
  echo "build-role-arn: $ROLE_ARN"

  log "2. package + upload code artifact (boto3)"
  py_upload_artifact

  log "3. create-microvm-image (CLI)"
  IMG_ARN_PRE="arn:aws:lambda:${REGION}:${ACCOUNT}:microvm-image:${NAME}"
  # idempotent: reuse if it already exists
  if aws lambda-microvms get-microvm-image --image-identifier "$IMG_ARN_PRE" --region "$REGION" >/dev/null 2>&1; then
    echo "image $NAME already exists, reusing"
  else
    aws lambda-microvms create-microvm-image \
      --name "$NAME" \
      --code-artifact "uri=s3://${BUCKET}/${KEY}" \
      --base-image-arn "$BASE_IMAGE_ARN" \
      --build-role-arn "$ROLE_ARN" \
      --description "minimal Flask MicroVM demo" \
      --region "$REGION"
  fi

  log "4. poll image build state (CREATING -> CREATED)"
  IMG_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:microvm-image:${NAME}"   # get-microvm-image needs the FULL ARN, not the short name
  for i in $(seq 1 66); do   # up to ~11 min
    STATE="$(aws lambda-microvms get-microvm-image --image-identifier "$IMG_ARN" --region "$REGION" --query 'state' --output text 2>/dev/null || echo UNKNOWN)"
    echo "  [$i] state=$STATE"
    [ "$STATE" = "CREATED" ] && break
    if [ "$STATE" = "CREATE_FAILED" ]; then
      echo "BUILD FAILED — build detail + logs:"
      aws lambda-microvms get-microvm-image --image-identifier "$IMG_ARN" --region "$REGION"
      aws logs tail "/aws/lambda-microvms/${NAME}" --region "$REGION" --since 15m 2>/dev/null | tail -30 || true
      exit 1
    fi
    sleep 10
  done

  log "5. run-microvm (CLI) — attach ingress+egress, idle auto-suspend"
  RUN_JSON="$(aws lambda-microvms run-microvm \
    --image-identifier "$IMG_ARN" \
    --ingress-network-connectors "$INGRESS_CONNECTOR" \
    --egress-network-connectors "$EGRESS_CONNECTOR" \
    --idle-policy '{"maxIdleDurationSeconds":300,"suspendedDurationSeconds":3600,"autoResumeEnabled":true}' \
    --maximum-duration-in-seconds 3600 \
    --region "$REGION")"
  echo "$RUN_JSON"
  MVM_ID="$(echo "$RUN_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["microvmId"])')"
  ENDPOINT="$(echo "$RUN_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("endpoint",""))')"
  printf 'MVM_ID=%s\nENDPOINT=%s\n' "$MVM_ID" "$ENDPOINT" > "$STATE_FILE"

  log "6. wait for RUNNING"
  for i in $(seq 1 30); do
    ST="$(aws lambda-microvms get-microvm --microvm-identifier "$MVM_ID" --region "$REGION" --query 'state' --output text)"
    echo "  [$i] microvm state=$ST"
    [ "$ST" = "RUNNING" ] && break
    sleep 5
  done
  # re-read endpoint in case run returned it empty
  [ -z "$ENDPOINT" ] && ENDPOINT="$(aws lambda-microvms get-microvm --microvm-identifier "$MVM_ID" --region "$REGION" --query 'endpoint' --output text)"

  # CONNECT CONTRACT (verified live): connect to the endpoint on PUBLIC 443
  # (NOT :5000). The token's allowed-ports must permit the CONTAINER port
  # ($APP_PORT), and you MUST send `X-aws-proxy-port: $APP_PORT` so the ingress
  # proxy knows which container port to forward to. Omitting that header makes
  # the request hang; a token that omits the container port returns
  # "Access to port denied".
  APP_PORT="${APP_PORT:-5000}"
  proxy_get() {  # $1 = path
    local tok
    tok="$(aws lambda-microvms create-microvm-auth-token --microvm-identifier "$MVM_ID" \
      --expiration-in-minutes 15 --allowed-ports "[{\"port\":${APP_PORT}}]" \
      --region "$REGION" --query 'authToken' --output text)"
    curl -sS --max-time 25 "https://${ENDPOINT}${1:-/}" \
      -H "X-aws-proxy-auth: ${tok}" -H "X-aws-proxy-port: ${APP_PORT}"; echo
  }

  log "7. mint short-lived auth token + curl the endpoint (443 + X-aws-proxy-port)"
  echo "hit 1:"; proxy_get /
  echo "hit 2 (counter should increment):"; proxy_get /
  echo "health:"; proxy_get /health

  log "8. suspend -> resume (prove in-VM state survives the snapshot)"
  aws lambda-microvms suspend-microvm --microvm-identifier "$MVM_ID" --region "$REGION" >/dev/null
  for i in $(seq 1 30); do ST="$(aws lambda-microvms get-microvm --microvm-identifier "$MVM_ID" --region "$REGION" --query 'state' --output text)"; echo "  suspend [$i] $ST"; [ "$ST" = "SUSPENDED" ] && break; sleep 5; done
  aws lambda-microvms resume-microvm --microvm-identifier "$MVM_ID" --region "$REGION" >/dev/null
  for i in $(seq 1 30); do ST="$(aws lambda-microvms get-microvm --microvm-identifier "$MVM_ID" --region "$REGION" --query 'state' --output text)"; echo "  resume  [$i] $ST"; [ "$ST" = "RUNNING" ] && break; sleep 5; done
  echo "after resume (hits continue, NOT reset to 1 = memory restored):"; proxy_get /

  log "DONE. VM is live: $MVM_ID  ($ENDPOINT). Run './flask_microvm.sh teardown' to remove everything."
}

cmd_teardown() {
  log "teardown: terminate VM + delete image + S3 + IAM role"
  if [ -f "$STATE_FILE" ]; then . "$STATE_FILE"; fi
  if [ -n "${MVM_ID:-}" ]; then
    aws lambda-microvms terminate-microvm --microvm-identifier "$MVM_ID" --region "$REGION" 2>/dev/null || true
    for i in $(seq 1 30); do ST="$(aws lambda-microvms get-microvm --microvm-identifier "$MVM_ID" --region "$REGION" --query 'state' --output text 2>/dev/null || echo GONE)"; echo "  term [$i] $ST"; { [ "$ST" = "TERMINATED" ] || [ "$ST" = "GONE" ]; } && break; sleep 5; done
  fi
  aws lambda-microvms delete-microvm-image --image-identifier "arn:aws:lambda:${REGION}:${ACCOUNT}:microvm-image:${NAME}" --region "$REGION" 2>/dev/null || true
python3 - "$BUCKET" "$KEY" "$ROLE" "$REGION" <<'PY'
import sys, boto3
bucket, key, role, region = sys.argv[1:5]
s3 = boto3.client("s3", region_name=region)
try:
    objs = s3.list_objects_v2(Bucket=bucket).get("Contents", [])
    if objs:
        s3.delete_objects(Bucket=bucket, Delete={"Objects":[{"Key":o["Key"]} for o in objs]})
    s3.delete_bucket(Bucket=bucket); print("deleted bucket", bucket)
except Exception as e:
    print("bucket cleanup:", e)
iam = boto3.client("iam")
try:
    for p in iam.list_role_policies(RoleName=role).get("PolicyNames", []):
        iam.delete_role_policy(RoleName=role, PolicyName=p)
    iam.delete_role(RoleName=role); print("deleted role", role)
except Exception as e:
    print("role cleanup:", e)
PY
  rm -f "$STATE_FILE"
  log "teardown complete."
}

case "${1:-up}" in
  up) cmd_up ;;
  teardown|down) cmd_teardown ;;
  *) echo "usage: $0 [up|teardown]"; exit 2 ;;
esac
