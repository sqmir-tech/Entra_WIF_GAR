# Pipeline: Entra ID (x509) → WIF → GAR — wersja modularna

Ta sama ścieżka co wcześniej (cert → token Entra → STS → SA → GAR), ale cała logika
wyniesiona do **osobnych skryptów** w `scripts/`. `.gitlab-ci.yml` tylko orkiestruje —
każdy etap jest testowalny lokalnie, bez GitLaba.

## Struktura repo

```
.
├── .gitlab-ci.yml              # orkiestracja: 5 stage'ów, każdy wywołuje 1 skrypt
├── Dockerfile                  # minimalny obraz testowy
├── .env.local.example          # szablon zmiennych do uruchomienia lokalnego
└── scripts/
    ├── lib.sh                  # wspólne funkcje (log, need, jwt_payload, save_env)
    ├── build-assertion.py      # buduje i podpisuje client assertion (x509)
    ├── 01-entra-token.sh       # cert → assertion → access token + weryfikacja CEL
    ├── 02-sts-exchange.sh      # access token → federacyjny token STS
    ├── 03-sa-impersonate.sh    # token STS → token Service Account
    ├── 04-gar-verify.sh        # sprawdzenie dostępu do repo (bez Dockera)
    ├── 05-gar-push.sh          # build + push przez Kaniko
    └── run-local.sh            # uruchamia 01→04 lokalnie, do debugowania
```

## Zalety tej struktury

- **Testowalność** — każdy skrypt uruchomisz osobno, bez czekania na runnera GitLab.
- **Czytelność YAML** — `.gitlab-ci.yml` pokazuje przepływ, nie tonie w bashu.
- **Reużywalność** — te same skrypty odpalisz z Jenkinsa, cron, lokalnie (`run-local.sh`).
- **Diff-friendly** — zmiana w logice etapu to zmiana w jednym pliku, nie w YAML.

## Konwencje w skryptach

Wszystkie źródłują `lib.sh`, które daje:

| Funkcja | Rola |
|---|---|
| `log/ok/err/die` | kolorowe komunikaty, `die` przerywa z kodem 1 |
| `need NAZWA` | zwraca wartość zmiennej env lub przerywa, jeśli pusta |
| `jwt_payload TOKEN` | dekoduje payload JWT do JSON |
| `save_env KLUCZ WART` | dopisuje do `tokens.env` (dotenv między jobami) |

## Uruchomienie w GitLab

### 1. CI/CD Variables (*Settings → CI/CD → Variables*)

| Zmienna | Typ | Maskowana | Wartość |
|---|---|---|---|
| `ENTRA_CERT_KEY` | **File** | tak | klucz prywatny `vendor-key.pem` |
| `ENTRA_CERT_PUB` | **File** | nie | certyfikat `vendor-cert.pem` |

Zmienne File w GitLab dają **ścieżkę do pliku** — skrypty czytają je jako ścieżki.

Zmienne nie-sekretne są w `variables:` w `.gitlab-ci.yml` — dostosuj do środowiska.

### 2. Push na `main` (lub `gar:push` ręcznie — `when: manual`)

Tokeny płyną między jobami przez dotenv artifact `tokens.env` (10 min ważności).

## Uruchomienie lokalne (debug, bez GitLaba)

```bash
cp .env.local.example .env.local
# uzupełnij .env.local — w tym ścieżki do vendor-key.pem / vendor-cert.pem
./scripts/run-local.sh
```

`run-local.sh` przechodzi etapy 01→04, przekazując tokeny przez `tokens.env` tak jak
GitLab. Etap 05 (Kaniko) uruchamiasz w środowisku z obrazem Kaniko.

Możesz też odpalać pojedynczo:
```bash
set -a; source .env.local; set +a
bash scripts/01-entra-token.sh      # zapisze ENTRA_TOKEN do tokens.env
set -a; source tokens.env; set +a
bash scripts/02-sts-exchange.sh
# itd.
```

## Wymagania jednorazowe (Entra + GCP)

Bez zmian względem wersji podstawowej:

- **Entra**: App Registration z certyfikatem (bez secret), App ID URI `api://CLIENT_ID`,
  App Role `gar-uploader` (Applications) przypisana + admin consent,
  `accessTokenAcceptedVersion: 2`.
- **GCP**: pool `entra-pool` + provider `entra-provider` (issuer `.../v2.0`, audience
  `api://CLIENT_ID`, CEL na `tid`/`azp`/`roles`/`azpacr`), SA `gar-uploader` z dwoma
  bindingami: `workloadIdentityUser` (principalSet → `attribute.app`) oraz
  `artifactregistry.writer` na repozytorium.

Komendy `gcloud` — patrz poprzedni README lub dokument `entra-cert-wif-gar.md`.

## Mapa błędów → skrypt

| Skrypt | Objaw | Przyczyna |
|---|---|---|
| `01` | brak tokenu, `AADSTS700027` | `x5t` ≠ wgrany cert |
| `01` | `azpacr != 2` | w App Registration jest jeszcze client secret |
| `01` | brak `roles` | App Role nieprzypisana / brak admin consent |
| `01` | `iss` bez `/v2.0` | `accessTokenAcceptedVersion` ≠ 2 |
| `02` | `invalid_grant` | `iss`/`aud` ≠ provider |
| `02` | odrzucenie mimo ważnego tokenu | token nie spełnia CEL |
| `03` | `getAccessToken denied` | brak bindingu `workloadIdentityUser` |
| `04` | HTTP 403 | brak `artifactregistry.writer` na repo |
| `05` | `denied: permission_denied` | jw. |
