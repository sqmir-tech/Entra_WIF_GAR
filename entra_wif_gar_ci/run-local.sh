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
echo ""; echo "Auth chain OK. Push (05) uruchomić w Kaniko."


ecit 0;


# =============================================================================
#  Entra ID (x509 cert) -> Workload Identity Federation -> Google Artifact Registry
#
#  Wersja z logiką wyniesioną do osobnych skryptów w scripts/.
#  .gitlab-ci.yml tylko orkiestruje — cała logika jest testowalna lokalnie.
#
#      ./scripts/01-entra-token.sh     # cert -> JWT
#      ./scripts/02-sts-exchange.sh    # JWT -> STS
#      ./scripts/03-sa-impersonate.sh  # STS -> SA
#      ./scripts/04-gar-verify.sh      # dostęp?
#      ./scripts/05-gar-push.sh        # Kaniko push
# =============================================================================

stages:
  - entra-token
  - sts-exchange
  - sa-impersonate
  - gar-verify
  - gar-push

variables:
  # --- Entra ---
  TENANT_ID: "1dc3fe6f-5823-4db4-8369-1d5d549c6967"
  CLIENT_ID: "8f0b4861-5fce-435e-8601-f50a5d58c4a3"
  # --- GCP ---
  GCP_PROJECT_ID: "my-project"
  GCP_PROJECT_NUMBER: "123456789012"
  GCP_REGION: "europe-central2"
  WIF_POOL: "entra-pool"
  WIF_PROVIDER: "entra-provider"
  GAR_REPO: "docker-test"
  GCP_SA: "gar-uploader@my-project.iam.gserviceaccount.com"
  # --- obraz ---
  IMAGE_NAME: "hello-entra-wif"
  IMAGE_TAG: "${CI_PIPELINE_IID}"

# --- wspólny fragment: obrazy z curl/jq/python dostają zależności ---
.alpine-tools: &alpine-tools
  before_script:
    - apk add --no-cache bash curl jq >/dev/null

entra:token:
  stage: entra-token
  image: python:3.12-slim
  before_script:
    - pip install --quiet cryptography
    - apt-get update -qq && apt-get install -y -qq bash jq curl >/dev/null
  script:
    - bash scripts/01-entra-token.sh
  artifacts:
    reports:
      dotenv: tokens.env
    expire_in: 10 minutes

sts:exchange:
  stage: sts-exchange
  image: alpine:3.20
  <<: *alpine-tools
  script:
    - bash scripts/02-sts-exchange.sh
  artifacts:
    reports:
      dotenv: tokens.env
    expire_in: 10 minutes

sa:impersonate:
  stage: sa-impersonate
  image: alpine:3.20
  <<: *alpine-tools
  script:
    - bash scripts/03-sa-impersonate.sh
  artifacts:
    reports:
      dotenv: tokens.env
    expire_in: 10 minutes

gar:verify:
  stage: gar-verify
  image: alpine:3.20
  <<: *alpine-tools
  script:
    - bash scripts/04-gar-verify.sh

gar:push:
  stage: gar-push
  image:
    name: gcr.io/kaniko-project/executor:v1.23.2-debug
    entrypoint: [""]
  script:
    - bash scripts/05-gar-push.sh
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
    - when: manual
      allow_failure: false
