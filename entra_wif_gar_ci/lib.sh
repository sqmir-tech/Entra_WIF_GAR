#!/usr/bin/env bash
# lib.sh — wspólne funkcje dla wszystkich etapów pipeline'u.
# Dołączane przez:  source "$(dirname "$0")/lib.sh"
set -euo pipefail

# --- logowanie ---
log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m OK\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m !!\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- wymagana zmienna środowiskowa ---
need() {
  local name="$1"
  local val="${!name:-}"
  [ -n "$val" ] || die "Brak wymaganej zmiennej: $name"
  printf '%s' "$val"
}

# --- dekoduje payload JWT do JSON (bez weryfikacji podpisu) ---
jwt_payload() {
  printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+' \
    | awk '{ while (length($0) % 4) $0 = $0 "="; print }' \
    | base64 -d 2>/dev/null
}

# --- zapisuje zmienną do pliku dotenv przekazywanego między jobami ---
save_env() {
  local key="$1" val="$2" file="${3:-tokens.env}"
  echo "${key}=${val}" >> "$file"
}
