#!/usr/bin/env bash
# curl a running Lambda MicroVM through its HTTPS endpoint.
# Mints a fresh auth token (they expire <=15 min) and sends the required
# X-aws-proxy-auth + X-aws-proxy-port headers on public 443.
#
# Usage: ./curl_microvm.sh <microvmId> <endpoint> [path] [containerPort]
#   ./curl_microvm.sh microvm-06dd... 3cd0...on.aws /            5000
#   ./curl_microvm.sh microvm-06dd... 3cd0...on.aws /health
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"; export AWS_PAGER=""
MVM="${1:?usage: $0 <microvmId> <endpoint> [path] [containerPort]}"
EP="${2:?endpoint required}"
PATH_="${3:-/}"
PORT="${4:-5000}"
REGION="${REGION:-us-east-1}"

TOKEN="$(aws lambda-microvms create-microvm-auth-token \
  --microvm-identifier "$MVM" --expiration-in-minutes 15 \
  --allowed-ports "[{\"port\":${PORT}}]" \
  --region "$REGION" --query authToken --output text)"

# connect on PUBLIC 443; X-aws-proxy-port tells the ingress proxy the target container port
curl -sS --max-time 30 "https://${EP}${PATH_}" \
  -H "X-aws-proxy-auth: ${TOKEN}" \
  -H "X-aws-proxy-port: ${PORT}"
echo
