#!/usr/bin/env bash
# 03-sa-impersonate.sh — token STS -> access token Service Account.
source "$(dirname "$0")/lib.sh"

STS_TOKEN=$(need STS_TOKEN)
SA=$(need GCP_SA)

log "Impersonacja SA (${SA})"
RESP=$(curl -sS -X POST \
  "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${SA}:generateAccessToken" \
  -H "Authorization: Bearer ${STS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"scope":["https://www.googleapis.com/auth/cloud-platform"]}')

SA_TOKEN=$(echo "$RESP" | jq -r '.accessToken // empty')
if [ -z "$SA_TOKEN" ]; then
  err "Impersonacja nieudana:"
  echo "$RESP" | jq . >&2
  err "Sprawdź binding roles/iam.workloadIdentityUser (principalSet -> attribute.app)."
  exit 1
fi

case "$SA_TOKEN" in
  ya29.*) ok "Token SA (ya29.…) uzyskany" ;;
  *)      die "Nietypowy format tokenu SA" ;;
esac

save_env SA_TOKEN "$SA_TOKEN"
