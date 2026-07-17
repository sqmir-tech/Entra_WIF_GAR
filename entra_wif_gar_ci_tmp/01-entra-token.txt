#!/usr/bin/env bash
# 01-entra-token.sh — cert -> client assertion -> access token Entra (JWT).
# Weryfikuje claimy pod kątem CEL providera. Zapisuje ENTRA_TOKEN do tokens.env.
source "$(dirname "$0")/lib.sh"

TENANT_ID=$(need TENANT_ID)
CLIENT_ID=$(need CLIENT_ID)
export CERT_KEY=$(need ENTRA_CERT_KEY)   # zmienna File -> ścieżka do pliku
export CERT_PUB=$(need ENTRA_CERT_PUB)

log "Buduję client assertion (podpis kluczem prywatnym)"
ASSERTION=$(python3 "$(dirname "$0")/build-assertion.py")
log "Assertion: długość=${#ASSERTION}, kropki=$(printf '%s' "$ASSERTION" | tr -cd '.' | wc -c)"

log "Wymieniam assertion na access token w Entra"
RESP=$(curl -sS -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "scope=api://${CLIENT_ID}/.default" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=${ASSERTION}")

ENTRA_TOKEN=$(echo "$RESP" | jq -r '.access_token // empty')
if [ -z "$ENTRA_TOKEN" ]; then
  err "Entra nie zwróciła tokenu:"
  echo "$RESP" | jq '{error, error_codes, error_description}' >&2
  exit 1
fi

log "Weryfikuję claimy tokenu względem CEL"
CLAIMS=$(jwt_payload "$ENTRA_TOKEN")
echo "$CLAIMS" | jq '{aud, iss, azp, azpacr, tid, roles, ver, ttl:(.exp-.iat)}'

fail=0
[ "$(echo "$CLAIMS" | jq -r .aud)"        = "api://${CLIENT_ID}" ] || { err "aud != api://CLIENT_ID"; fail=1; }
[ "$(echo "$CLAIMS" | jq -r .azpacr)"     = "2" ]                  || { err "azpacr != 2 (użyto sekretu zamiast certu?)"; fail=1; }
[ "$(echo "$CLAIMS" | jq -r '.roles[0]')" = "gar-uploader" ]      || { err "brak roli gar-uploader"; fail=1; }
echo "$(echo "$CLAIMS" | jq -r .iss)" | grep -q '/v2.0$'          || { err "iss nie kończy się /v2.0 (token v1.0?)"; fail=1; }
[ "$fail" = "0" ] || die "Token nie przejdzie CEL providera."

save_env ENTRA_TOKEN "$ENTRA_TOKEN"
ok "Access token gotowy do wymiany w STS"
