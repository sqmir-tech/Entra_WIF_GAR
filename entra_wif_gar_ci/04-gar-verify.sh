#!/usr/bin/env bash
# 04-gar-verify.sh — sprawdza dostęp SA do repo GAR realnym endpointem (bez Dockera).
# Token federacyjny jest opaque -> tokeninfo nie zadziała, używamy Artifact Registry API.
source "$(dirname "$0")/lib.sh"

SA_TOKEN=$(need SA_TOKEN)
PROJECT_ID=$(need GCP_PROJECT_ID)
REGION=$(need GCP_REGION)
REPO=$(need GAR_REPO)

log "Sprawdzam dostęp do repozytorium ${REPO}"
RESP=$(curl -sS -w '\n%{http_code}' \
  "https://artifactregistry.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/repositories/${REPO}" \
  -H "Authorization: Bearer ${SA_TOKEN}")
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')

if [ "$CODE" = "200" ]; then
  echo "$BODY" | jq '{name, format, mode}'
  ok "SA ma dostęp do repo — ścieżka auth potwierdzona przed pushem"
else
  err "Dostęp do repo odrzucony (HTTP ${CODE}):"
  echo "$BODY" | jq . >&2
  die "Sprawdź roles/artifactregistry.writer na repozytorium ${REPO}."
fi
