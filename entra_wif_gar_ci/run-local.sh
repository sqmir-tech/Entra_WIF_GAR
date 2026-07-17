#!/usr/bin/env bash
# run-local.sh — uruchamia cały łańcuch lokalnie (poza GitLabem), do debugowania.
# Symuluje przekazywanie tokenów przez tokens.env między etapami.
# Wymaga: python3+cryptography, curl, jq oraz ustawionych zmiennych (patrz README).
set -euo pipefail
cd "$(dirname "$0")/.."

# załaduj zmienne nie-sekretne, jeśli istnieje .env.local
[ -f .env.local ] && set -a && source .env.local && set +a

rm -f tokens.env
run() {
  echo ""; echo "########## $1 ##########"
  set -a; [ -f tokens.env ] && source tokens.env; set +a
  bash "scripts/$1"
}
run 01-entra-token.sh
run 02-sts-exchange.sh
run 03-sa-impersonate.sh
run 04-gar-verify.sh
echo ""; echo "Łańcuch auth OK. Push (05) uruchom w środowisku z Kaniko."
