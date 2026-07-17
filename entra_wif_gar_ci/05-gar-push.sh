#!/usr/bin/env bash
# 05-gar-push.sh — konfiguruje auth Kaniko tokenem SA i wypycha obraz do GAR.
# Uruchamiany w obrazie Kaniko (executor). Nie wymaga docker daemon.
source "$(dirname "$0")/lib.sh"

SA_TOKEN=$(need SA_TOKEN)
PROJECT_ID=$(need GCP_PROJECT_ID)
REGION=$(need GCP_REGION)
REPO=$(need GAR_REPO)
IMAGE_NAME=$(need IMAGE_NAME)
IMAGE_TAG=$(need IMAGE_TAG)

REGISTRY="${REGION}-docker.pkg.dev"
DEST="${REGISTRY}/${PROJECT_ID}/${REPO}/${IMAGE_NAME}:${IMAGE_TAG}"
log "Cel: ${DEST}"

log "Konfiguruję auth Kaniko (oauth2accesstoken)"
AUTH=$(printf 'oauth2accesstoken:%s' "$SA_TOKEN" | base64 | tr -d '\n')
mkdir -p /kaniko/.docker
cat > /kaniko/.docker/config.json <<JSON
{ "auths": { "${REGISTRY}": { "auth": "${AUTH}" } } }
JSON

log "Buduję i wypycham obraz"
/kaniko/executor \
  --context "${CI_PROJECT_DIR}" \
  --dockerfile "${CI_PROJECT_DIR}/Dockerfile" \
  --destination "${DEST}" \
  --verbosity info

ok "Obraz wypchnięty: ${DEST}"
