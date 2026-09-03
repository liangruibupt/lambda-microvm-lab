#!/usr/bin/env bash
# =============================================================================
# Multi-tenant AI agents on Lambda MicroVMs — follow-along runbook.
#
# Wraps the official sample:
#   github.com/aws-samples/sample-multi-tenant-ai-agents-on-lambda-microvm
# It is CloudFormation-based (src/template.yaml); deploy.sh is a thin wrapper.
#
# ⚠️  BILLABLE. `deploy` stands up a NAT gateway (~$32/month, per-stack, always
#     on) plus EFS/DynamoDB/Lambda/API-Gateway/MicroVM-image. Everything except
#     the NAT idles near $0. `teardown` removes all of it.
#
# Usage:
#   ./multitenant_sample.sh clone
#   ./multitenant_sample.sh deploy                       # prompts for cost OK
#   ./multitenant_sample.sh add-tenant tenant1           # HTTP-only tenant
#   ./multitenant_sample.sh add-tenant tenant1 <BOT_TOKEN> <SECRET>   # Telegram
#   ./multitenant_sample.sh chat tenant1 "remember my lucky number is 7777"
#   ./multitenant_sample.sh chat tenant1 "what is my lucky number?"
#   ./multitenant_sample.sh teardown
#
# Prereqs (verified from the sample README):
#   * AWS CLI v2 >= 2.35 with `lambda-microvms` AND `lambda-core` subcommands
#     -> ensured here by prepending ~/.local/bin (our 2.36.37).
#   * python3 + pip, zip, curl, openssl.
#   * Region where MicroVMs launched (us-east-1 verified). deploy.sh probes it.
#   * Bedrock: Claude models enabled in the region (vision-capable for images).
#   * Telegram bot token only for the push path (dedicated bot per tenant).
#   * Docker NOT required locally (image builds on AWS).
# =============================================================================
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
export AWS_PAGER=""

STACK="${STACK:-openclaw-mt}"
REGION="${REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${HERE}/sample-multi-tenant-ai-agents-on-lambda-microvm"
SRC="${REPO}/src"
GIT_URL="https://github.com/aws-samples/sample-multi-tenant-ai-agents-on-lambda-microvm.git"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

need_repo() { [ -d "$SRC" ] || { echo "repo not cloned. run: $0 clone"; exit 1; }; }

case "${1:-help}" in
  clone)
    log "cloning $GIT_URL"
    [ -d "$REPO" ] && { echo "already cloned at $REPO"; exit 0; }
    git clone --depth 1 "$GIT_URL" "$REPO"
    echo "cloned. read $REPO/README.md and $SRC/README.md, then: $0 deploy"
    ;;

  preflight)
    need_repo
    log "preflight checks"
    aws --version
    echo "-- lambda-microvms present:"; aws lambda-microvms help >/dev/null 2>&1 && echo OK || echo MISSING
    echo "-- lambda-core present:";     aws lambda-core help     >/dev/null 2>&1 && echo OK || echo MISSING
    echo "-- MicroVMs reachable in $REGION:"; aws lambda-microvms list-microvms --region "$REGION" >/dev/null 2>&1 && echo OK || echo UNREACHABLE
    echo "-- Bedrock Claude access ($REGION):"; aws bedrock list-foundation-models --region "$REGION" --query "modelSummaries[?contains(modelId,'claude')].modelId" --output text 2>/dev/null | tr '\t' '\n' | head
    for t in python3 pip zip curl openssl git; do command -v "$t" >/dev/null && echo "-- $t OK" || echo "-- $t MISSING"; done
    ;;

  deploy)
    need_repo
    cat <<EOF

⚠️  This deploys a BILLABLE stack:
      * NAT gateway  ~\$32/month  (always-on, per-stack; drop it if agents
        do not need internet — see the sample README)
      * EFS / DynamoDB / Lambda / API Gateway / MicroVM image (~\$0 idle)
    Deploy time ~10 min. Teardown with: $0 teardown

EOF
    read -r -p "Type 'deploy' to proceed: " ans
    [ "$ans" = "deploy" ] || { echo "aborted."; exit 1; }
    log "deploy.sh $STACK $REGION"
    ( cd "$SRC" && ./deploy.sh "$STACK" "$REGION" )
    ;;

  add-tenant)
    need_repo; TENANT="${2:?usage: $0 add-tenant <tenantId> [botToken secret]}"
    log "add-tenant $TENANT"
    if [ -n "${3:-}" ] && [ -n "${4:-}" ]; then
      ( cd "$SRC" && ./add-tenant.sh "$STACK" "$REGION" "$TENANT" "$3" "$4" )   # Telegram
    else
      ( cd "$SRC" && ./add-tenant.sh "$STACK" "$REGION" "$TENANT" )             # HTTP-only
    fi
    ;;

  chat)
    need_repo; TENANT="${2:?usage: $0 chat <tenantId> \"message\" [sessionKey]}"; MSG="${3:?message required}"
    log "chat $TENANT (first turn cold-starts the VM ~90s)"
    ( cd "$SRC" && ./chat.sh "$STACK" "$REGION" "$TENANT" "$MSG" "${4:-}" )
    ;;

  teardown|down)
    need_repo
    log "teardown.sh $STACK $REGION (terminates this stack's VMs, deletes stack + artifact bucket)"
    ( cd "$SRC" && ./teardown.sh "$STACK" "$REGION" )
    echo "if it stalls on VPC/SG (ENIs detaching), just re-run — CFN delete is idempotent."
    ;;

  *)
    grep -E '^#( |=)' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
