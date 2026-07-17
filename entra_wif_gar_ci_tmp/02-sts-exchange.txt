#!/usr/bin/env bash
# 02-sts-exchange.sh — access token Entra -> federacyjny token STS.
source "$(dirname "$0")/lib.sh"

ENTRA_TOKEN=$(need ENTRA_TOKEN)
PROJECT_NUMBER=$(need GCP_PROJECT_NUMBER)
POOL=$(need WIF_POOL)
PROVIDER=$(need WIF_PROVIDER)

POOL_RESOURCE="//iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
log "Wymiana w STS (audience = ${POOL_RESOURCE})"

RESP=$(curl -sS -X POST "https://sts.googleapis.com/v1/token" \
  -H "Content-Type: application/json" \
  -d "{
    \"grantType\": \"urn:ietf:params:oauth:grant-type:token-exchange\",
    \"audience\": \"${POOL_RESOURCE}\",
    \"scope\": \"https://www.googleapis.com/auth/cloud-platform\",
    \"requestedTokenType\": \"urn:ietf:params:oauth:token-type:access_token\",
    \"subjectToken\": \"${ENTRA_TOKEN}\",
    \"subjectTokenType\": \"urn:ietf:params:oauth:token-type:jwt\"
  }")

STS_TOKEN=$(echo "$RESP" | jq -r '.access_token // empty')
if [ -z "$STS_TOKEN" ]; then
  err "Wymiana STS nieudana:"
  echo "$RESP" | jq . >&2
  err "Częste przyczyny: iss/aud != provider, token nie spełnia CEL, token wygasł."
  exit 1
fi

save_env STS_TOKEN "$STS_TOKEN"
ok "Federacyjny token STS uzyskany"
