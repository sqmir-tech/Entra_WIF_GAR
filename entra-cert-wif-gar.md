# Entra ID (certyfikat x509) → Workload Identity Federation → Google Artifact Registry

Uwierzytelnianie zewnętrznego dostawcy do wgrywania artefaktów (obraz Docker, repozytorium
Maven) do Google Artifact Registry, bez długożyjących kluczy Service Account i bez client
secret. Dostawca uwierzytelnia się **kluczem prywatnym (x509)**, a GCP przyjmuje token
przez **Workload Identity Federation**.

Dokument analogiczny do `gitlab-oidc-gar-docker.md` — ten sam wzorzec (JWT → GCP STS → GAR),
inny dostawca tożsamości (Entra ID zamiast GitLab, uwierzytelnienie certyfikatem zamiast
OIDC pipeline'u).

test

---

## Spis treści

1. [Architektura](#1-architektura)
2. [Model tożsamości: WIF vs Workforce IF, Pool vs Provider](#2-model-tożsamości)
3. [Rejestracja aplikacji w Entra ID (certyfikat, bez sekretu)](#3-rejestracja-aplikacji-w-entra-id)
4. [Konfiguracja WIF po stronie GCP](#4-konfiguracja-wif-po-stronie-gcp)
5. [Uprawnienia GAR i binding IAM](#5-uprawnienia-gar-i-binding-iam)
6. [Warunki CEL (attribute condition)](#6-warunki-cel)
7. [Żądanie tokenu po stronie klienta](#7-żądanie-tokenu-po-stronie-klienta)
8. [Wymiana tokenu w GCP STS i uzyskanie tokenu SA](#8-wymiana-tokenu-w-gcp-sts)
9. [Wgrywanie artefaktów: Docker i Maven](#9-wgrywanie-artefaktów)
10. [Walidacja tokenu — jak działa pod spodem](#10-walidacja-tokenu)
11. [Debugowanie i najczęstsze błędy](#11-debugowanie)
12. [Checklist bezpieczeństwa](#12-checklist-bezpieczeństwa)
13. [Placeholdery](#13-placeholdery)

{
  "aud": "api://8f0b4861-5fce-435e-8601-f50a5d58c4a3",
  "iss": "https://sts.windows.net/1dc3fe6f-5823-4db4-8369-1d5d549c6967/",
  "azp": null,
  "azpacr": null,
  "tid": "1dc3fe6f-5823-4db4-8369-1d5d549c6967",
  "roles": null,
  "ttl_sec": 3900
}

---

## 1. Architektura

```
Dostawca (klient)                          Twoja firma
─────────────────                          ───────────────────────────────
klucz prywatny x509                        Entra ID (App Registration)
        │                                  publiczny .cer wgrany do aplikacji
        │  1. client assertion (JWT
        │     podpisany kluczem priv.)
        └──────────────────────────────────────────►  token endpoint Entra
                                                              │
                            2. access token (JWT, aud=api://CLIENT_ID, azpacr=2)
        ◄─────────────────────────────────────────────────────┘
        │
        │  3. wymiana tokenu
        └──────────────────────────────►  GCP STS (securitytoken.googleapis.com)
                                                  │  weryfikacja: JWKS(Entra),
                                                  │  iss, aud, exp, CEL
                                                  ▼
                                          Workload Identity Pool + Provider
                                                  │  4. impersonacja
                                                  ▼
                                          Service Account: gar-uploader@...
                                                  │  roles/artifactregistry.writer
                                                  ▼
                                          Google Artifact Registry
                                          (docker-repo / maven-repo)
```

Przepływ w skrócie:

1. Klient podpisuje **client assertion** swoim kluczem prywatnym.
2. Entra ID weryfikuje ją publicznym certyfikatem i wystawia **access token** (JWT).
3. Klient wymienia access token w **GCP STS** na federacyjny token STS.
4. Federacyjny token impersonuje **Service Account**, który ma prawo zapisu w GAR.
5. Klient wgrywa artefakt (`docker push` / `mvn deploy`).

---

## 2. Model tożsamości

### Workload Identity Federation vs Workforce Identity Federation

| Cecha | **Workload Identity Federation** | **Workforce Identity Federation** |
|---|---|---|
| Tożsamość | maszyna / aplikacja / pipeline | człowiek (pracownik) |
| Zasób GCP | Workload Identity Pool (per projekt) | Workforce Identity Pool (per organizacja) |
| Użycie | automatyczne, bezobsługowe | interaktywne (SSO, przeglądarka) |
| Ten scenariusz | **TAK** — dostawca to workload | nie |

Dostawca wgrywa artefakty automatycznie (proces, nie człowiek) → **Workload Identity Federation**.

### Pool vs Provider

- **Workload Identity Pool** — logiczny kontener tożsamości federacyjnych, tworzony per projekt
  GCP. Definiuje przestrzeń nazw (`principalSet://.../workloadIdentityPools/POOL/...`) używaną
  w bindingach IAM. Może zawierać wiele providerów.
- **Workload Identity Provider** — konfiguracja jednego IdP wewnątrz poola. Określa issuer,
  dozwolone audience, mapowanie atrybutów i warunek CEL. Decyduje, *czy token wpuścić i jak
  go zrozumieć*.

Relacja hierarchiczna: provider zawsze należy do dokładnie jednego poola.

```
Pool: entra-pool
   └── Provider: entra-provider  (OIDC, issuer = Entra ID tenanta)
```

---

## 3. Rejestracja aplikacji w Entra ID

Uwierzytelnienie **certyfikatem**, **bez client secret**. Certyfikat i secret to metody
alternatywne — obecność certyfikatu w pełni zastępuje sekret.

### 3.1. Utwórz App Registration

Entra admin center → *App registrations* → *New registration*. Zanotuj:
- **Application (client) ID** → `CLIENT_ID`
- **Directory (tenant) ID** → `TENANT_ID`

### 3.2. Wgraj publiczny certyfikat (nie generuj sekretu)

*Certificates & secrets → Certificates → Upload certificate* → wgraj **publiczny `.cer`
/ `.pem`** (bez klucza prywatnego).

```
Certificates & secrets
├── Certificates       →  WGRAJ publiczny .cer   (klucz prywatny zostaje u klienta)
├── Client secrets     →  PUSTE  (NIE generuj)
└── Federated creds    →  PUSTE  (nieużywane w tym wariancie)
```

- Klucz prywatny **nigdy** nie trafia do Entra — zostaje wyłącznie u dostawcy.
- Nie wgrywaj `.pfx` / `.p12` z kluczem prywatnym — nie jest wymagane i łamie rozdział kluczy.
- Można wgrać kilka certyfikatów naraz (rotacja bez przestoju).
- Pilnuj daty `notAfter` — po wygaśnięciu Entra odrzuci assertion.

**Dlaczego bez sekretu:** obecność sekretu zostawiłaby słabszą, alternatywną furtkę
uwierzytelnienia. Uwierzytelnienie certyfikatem daje w tokenie `azpacr == '2'`, co można
wymusić warunkiem CEL — ale tylko sensownie, gdy sekret nie istnieje jako alternatywa.

### 3.3. Skonfiguruj App ID URI (audience)

*Expose an API → Application ID URI* → ustaw `api://CLIENT_ID`.

To **krytyczne**: dzięki temu klient prosi o token ze scope `api://CLIENT_ID/.default`,
a wydany access token ma `aud = api://CLIENT_ID` i jest **dekodowalnym JWT** (nie token
opaque). Token z `aud` wskazującym na zasób Microsoftu (np. Graph) bywa opaque i WIF go
nie zwaliduje.

### 3.4. (Zalecane) Zdefiniuj App Role

*App roles → Create app role*:
- Value: `gar-uploader`
- Allowed member types: *Applications*

Rola pojawi się w tokenie jako `roles: ["gar-uploader"]` i posłuży do warunku CEL. Przypisz
rolę aplikacji dostawcy (*Enterprise applications → Permissions* lub przez admin consent).

---

## 4. Konfiguracja WIF po stronie GCP

```bash
PROJECT_ID="my-project"
PROJECT_NUMBER="123456789012"
TENANT_ID="9f8e7d6c-aaaa-bbbb-cccc-1234567890ab"
CLIENT_ID="a1b2c3d4-1111-2222-3333-444455556666"

# 1. Pool
gcloud iam workload-identity-pools create entra-pool \
  --location=global \
  --project="$PROJECT_ID" \
  --display-name="Entra ID vendor pool"

# 2. Provider OIDC
gcloud iam workload-identity-pools providers create-oidc entra-provider \
  --location=global \
  --project="$PROJECT_ID" \
  --workload-identity-pool=entra-pool \
  --issuer-uri="https://login.microsoftonline.com/${TENANT_ID}/v2.0" \
  --allowed-audiences="api://${CLIENT_ID}" \
  --attribute-mapping="google.subject=assertion.sub,attribute.tenant=assertion.tid,attribute.app=assertion.azp" \
  --attribute-condition="assertion.tid == '${TENANT_ID}' && assertion.azp == '${CLIENT_ID}' && 'gar-uploader' in assertion.roles && assertion.azpacr == '2'"
```

- **`issuer-uri`** kończy się na `/v2.0` — wymuś tokeny v2.0 (`accessTokenAcceptedVersion: 2`
  w manifeście aplikacji), by mapowania (`azp`, `tid`) były spójne.
- **`allowed-audiences`** = `api://CLIENT_ID` — musi dokładnie odpowiadać `aud` tokenu.
- **`attribute-condition`** — patrz sekcja [6](#6-warunki-cel).

---

## 5. Uprawnienia GAR i binding IAM

```bash
REGION="europe-central2"

# Service Account, który realnie ma prawo zapisu w GAR
gcloud iam service-accounts create gar-uploader \
  --project="$PROJECT_ID" \
  --display-name="GAR uploader (vendor via Entra)"

SA="gar-uploader@${PROJECT_ID}.iam.gserviceaccount.com"

# WAŻNE: nadaj writer na KONKRETNYM repozytorium, nie na całym projekcie
gcloud artifacts repositories add-iam-policy-binding docker-repo \
  --location="$REGION" --project="$PROJECT_ID" \
  --member="serviceAccount:${SA}" \
  --role="roles/artifactregistry.writer"

gcloud artifacts repositories add-iam-policy-binding maven-repo \
  --location="$REGION" --project="$PROJECT_ID" \
  --member="serviceAccount:${SA}" \
  --role="roles/artifactregistry.writer"

# Pozwól tożsamości federacyjnej impersonować SA — zawężone do konkretnej aplikacji
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/entra-pool/attribute.app/${CLIENT_ID}"
```

Dwie warstwy zawężenia:
- **CEL na providerze** — odsiewa obce tokeny (tenant, aplikacja, rola, cert).
- **`principalSet` w bindingu IAM** — ogranicza, która wpuszczona tożsamość może impersonować
  ten konkretny SA (tu: `attribute.app/CLIENT_ID`).

---

## 6. Warunki CEL

Attribute condition działa na poziomie **providera** — filtr wpuszczający, ewaluowany po
weryfikacji podpisu, issuera i audience, a przed mapowaniem atrybutów.

Zestaw dla tego scenariusza (tenant + aplikacja + rola + wymuszony certyfikat):

```
assertion.tid == 'TENANT_ID' &&
assertion.azp == 'CLIENT_ID' &&
'gar-uploader' in assertion.roles &&
assertion.azpacr == '2'
```

| Warunek | Chroni przed |
|---|---|
| `assertion.tid == 'TENANT_ID'` | tokenami z cudzego tenanta Azure (**obowiązkowe**) |
| `assertion.azp == 'CLIENT_ID'` | tokenami z innej aplikacji w tym samym tenancie |
| `'gar-uploader' in assertion.roles` | aplikacjami bez przypisanej roli uploadu |
| `assertion.azpacr == '2'` | uwierzytelnieniem sekretem zamiast certyfikatu |

Zasady:
- Warunek musi odnosić się do claimów, które token **faktycznie** zawiera — inaczej błąd
  ewaluacji i odrzucenie.
- Pojedyncze wyrażenie boolowskie (do 4096 znaków); złożoność buduj przez `&&` / `||`.
- Testuj przyrostowo — najpierw sam `tid`, potem dokładaj warunki.

---

## 7. Żądanie tokenu po stronie klienta

Klient uwierzytelnia się kluczem prywatnym. **Scope musi być `api://CLIENT_ID/.default`** —
to on gwarantuje, że `aud` wskaże na własne API i token będzie dekodowalnym JWT.

### 7.1. MSAL (zalecane produkcyjnie)

MSAL sam buduje i podpisuje client assertion (`x5t`, JWT-bearer).

```python
import msal

TENANT_ID = "9f8e7d6c-aaaa-bbbb-cccc-1234567890ab"
CLIENT_ID = "a1b2c3d4-1111-2222-3333-444455556666"

app = msal.ConfidentialClientApplication(
    client_id=CLIENT_ID,
    authority=f"https://login.microsoftonline.com/{TENANT_ID}",
    client_credential={
        "private_key": open("vendor-private-key.pem").read(),   # tylko u klienta
        "thumbprint": "A1B2C3...",                              # SHA-1 wgranego .cer
        # "public_certificate": open("vendor.cer").read(),      # opcjonalnie (x5c/SNI)
    },
)

result = app.acquire_token_for_client(
    scopes=[f"api://{CLIENT_ID}/.default"]     # <-- /.default na własnym App ID URI
)

if "access_token" not in result:
    raise RuntimeError(result.get("error_description"))
access_token = result["access_token"]
```

`acquire_token_for_client` = flow client credentials (app-only). Dla app-only scope to zawsze
`<resource>/.default`, nie pojedyncze uprawnienia.

### 7.2. Surowy HTTP (do zrozumienia / debugowania)

```bash
curl -s -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -d "client_id=${CLIENT_ID}" \
  -d "scope=api://${CLIENT_ID}/.default" \
  -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=${CLIENT_ASSERTION}" | jq -r .access_token
```

`CLIENT_ASSERTION` — JWT podpisany kluczem prywatnym klienta:
- **header**: `{"alg":"RS256","typ":"JWT","x5t":"<thumbprint .cer>"}`
- **payload**: `{"aud":"https://login.microsoftonline.com/TENANT/oauth2/v2.0/token","iss":CLIENT_ID,"sub":CLIENT_ID,"jti":<uuid>,"exp":now+600,"nbf":now,"iat":now}`

Uwaga na dwa różne `aud`:

| Token | `aud` | Znaczenie |
|---|---|---|
| Client assertion (żądanie) | token endpoint `.../oauth2/v2.0/token` | JWT dla Entra, by uwierzytelnić klienta |
| Access token (odpowiedź) | `api://CLIENT_ID` | token dla własnego API — ten leci do WIF |

### 7.3. Weryfikacja, że wynik to dekodowalny JWT

```bash
echo "$access_token" | cut -d. -f2 | tr '_-' '/+' | \
  awk '{ while(length($0)%4) $0=$0"="; print }' | base64 -d | \
  jq '{aud, iss, azp, azpacr, tid, roles}'
```

Oczekiwany wynik:

```json
{
  "aud": "api://a1b2c3d4-1111-2222-3333-444455556666",
  "iss": "https://login.microsoftonline.com/9f8e7d6c-.../v2.0",
  "azp": "a1b2c3d4-1111-2222-3333-444455556666",
  "azpacr": "2",
  "tid": "9f8e7d6c-aaaa-bbbb-cccc-1234567890ab",
  "roles": ["gar-uploader"]
}
```

Punkty kontrolne: `aud == api://CLIENT_ID` (JWT, nie opaque), `azpacr == '2'` (certyfikat),
`roles` zawiera `gar-uploader`, `tid` = Twój tenant.

> Typ tokenu: to **OAuth 2.0 access token**, nie OIDC ID token (flow app-only nie wystawia
> ID tokenu). WIF akceptuje go, bo waliduje dowolny JWT metodą OIDC discovery + JWKS — „OIDC"
> w nazwie providera oznacza *sposób walidacji*, nie wymóg, że token jest ID tokenem.

---

## 8. Wymiana tokenu w GCP STS

Dwustopniowo: access token Entra → federacyjny token STS → access token SA.

```bash
POOL_RESOURCE="//iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/entra-pool/providers/entra-provider"
SA="gar-uploader@${PROJECT_ID}.iam.gserviceaccount.com"

# 1. Entra access token -> federacyjny token STS
STS_TOKEN=$(curl -s -X POST "https://sts.googleapis.com/v1/token" \
  -H "Content-Type: application/json" \
  -d "{
    \"grantType\": \"urn:ietf:params:oauth:grant-type:token-exchange\",
    \"audience\": \"${POOL_RESOURCE}\",
    \"scope\": \"https://www.googleapis.com/auth/cloud-platform\",
    \"requestedTokenType\": \"urn:ietf:params:oauth:token-type:access_token\",
    \"subjectToken\": \"${access_token}\",
    \"subjectTokenType\": \"urn:ietf:params:oauth:token-type:jwt\"
  }" | jq -r .access_token)

# 2. Federacyjny token STS -> access token SA (impersonacja)
SA_TOKEN=$(curl -s -X POST \
  "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${SA}:generateAccessToken" \
  -H "Authorization: Bearer ${STS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"scope":["https://www.googleapis.com/auth/cloud-platform"]}' \
  | jq -r .accessToken)
```

Rozróżnienie dwóch `audience`, których nie wolno mylić:
- **`aud` w JWT Entra** = `api://CLIENT_ID` (co sprawdza `allowedAudiences`).
- **`audience` w żądaniu STS** = pełny resource path providera (`//iam.googleapis.com/...`).

> **Opcja bez impersonacji.** Federacyjny token STS można w niektórych konfiguracjach użyć
> bezpośrednio (direct resource access). Wtedy jednak token jest **opaque** — nieintrospekowalny
> przez `tokeninfo`. Impersonacja SA daje czytelny access token i lepszą obserwowalność
> (w logach widać email SA zamiast surowego `principalSet://`). Zalecana ścieżka: impersonacja.

---

## 9. Wgrywanie artefaktów

### Docker

```bash
echo "$SA_TOKEN" | docker login -u oauth2accesstoken \
  --password-stdin "${REGION}-docker.pkg.dev"

docker tag my-image:latest \
  "${REGION}-docker.pkg.dev/${PROJECT_ID}/docker-repo/my-image:latest"

docker push "${REGION}-docker.pkg.dev/${PROJECT_ID}/docker-repo/my-image:latest"
```

### Maven

`settings.xml`:

```xml
<settings>
  <servers>
    <server>
      <id>gar-maven</id>
      <username>oauth2accesstoken</username>
      <password>${env.SA_TOKEN}</password>
    </server>
  </servers>
</settings>
```

`pom.xml`:

```xml
<distributionManagement>
  <repository>
    <id>gar-maven</id>
    <url>artifactregistry://${REGION}-maven.pkg.dev/${PROJECT_ID}/maven-repo</url>
  </repository>
</distributionManagement>
```

Deploy (z rozszerzeniem `artifactregistry-maven-wagon` w `pom.xml` lub `extensions.xml`):

```bash
export SA_TOKEN
mvn deploy -s settings.xml
```

---

## 10. Walidacja tokenu

Co robi GCP STS przy wymianie (w kolejności — token musi przejść każdy etap):

1. **Parsowanie struktury** — rozbicie `header.payload.signature`, odczyt `alg`, `kid`.
2. **Weryfikacja podpisu** — OIDC discovery `{issuer}/.well-known/openid-configuration` →
   `jwks_uri` → klucz publiczny wg `kid` → sprawdzenie podpisu. Bezstanowe, bez sekretów po
   stronie GCP; rotacja kluczy Entra propaguje się automatycznie.
3. **`iss`** = `issuer-uri` providera (dokładne dopasowanie).
4. **`aud`** ∈ `allowedAudiences` (`api://CLIENT_ID`).
5. **`exp` / `nbf` / `iat`** — ważność czasowa (z marginesem clock skew).
6. **Attribute condition (CEL)** — na surowych `assertion.*`.
7. **Attribute mapping** — przepisanie claimów na `google.subject`, `attribute.*`.

Dwa niezależne „zamki": `iss` mówi *od kogo*, `aud` mówi *dla kogo* — oba muszą pasować.
Sama walidacja podpisu i `aud` nie gwarantuje pochodzenia z Twojego tenanta, jeśli issuer
byłby wielotenantowy — stąd `assertion.tid` jako warstwa obowiązkowa w CEL.

---

## 11. Debugowanie

| Objaw | Prawdopodobna przyczyna | Gdzie szukać |
|---|---|---|
| `invalid_grant` przy wymianie STS | `aud` ≠ `allowedAudiences` lub `iss` ≠ `issuer-uri` | scope `/.default`, App ID URI, `/v2.0` w issuerze |
| Token nie da się zdekodować (opaque) | `aud` wskazuje na zasób MS, nie `api://CLIENT_ID` | scope musi być `api://CLIENT_ID/.default` |
| Odrzucenie mimo poprawnego tokenu | warunek CEL zwrócił `false` | zdekoduj token, porównaj `tid`/`azp`/`roles`/`azpacr` |
| `azpacr == '1'` mimo certyfikatu | w aplikacji istnieje jeszcze client secret i użyto go | usuń secret z App Registration |
| `AADSTS700027` | thumbprint w `x5t` ≠ wgrany `.cer` | dopasuj certyfikat/klucz po stronie klienta |
| `Permission denied` przy `docker push` | brak `artifactregistry.writer` na repo | binding IAM na konkretnym repozytorium |
| Błąd ewaluacji CEL | warunek odnosi się do nieistniejącego claimu | zdekoduj realny token, sprawdź dostępne pola |

Ręczna weryfikacja podpisu (debug): pobierz `jwks_uri` z
`https://login.microsoftonline.com/${TENANT_ID}/v2.0/.well-known/openid-configuration`,
wybierz klucz wg `kid` z nagłówka tokenu, zweryfikuj podpis lokalnie.

Weryfikacja tokenu SA (jest opaque — `tokeninfo` nie zadziała): użyj wywołania API, np.
`gcloud artifacts repositories list` z tym tokenem lub `testIamPermissions` na repozytorium.

---

## 12. Checklist bezpieczeństwa

- [ ] App Registration ma **certyfikat**, **nie ma client secret**.
- [ ] Wgrana tylko część publiczna certyfikatu (`.cer`), klucz prywatny wyłącznie u klienta.
- [ ] App ID URI = `api://CLIENT_ID`; klient prosi o scope `api://CLIENT_ID/.default`.
- [ ] `allowedAudiences` providera = `api://CLIENT_ID` (dokładnie).
- [ ] CEL wymusza `tid` (obowiązkowo), `azp`, `roles`, `azpacr == '2'`.
- [ ] `roles/artifactregistry.writer` nadany na **konkretnych repozytoriach**, nie na projekcie.
- [ ] `principalSet` w bindingu IAM zawężony do `attribute.app/CLIENT_ID`.
- [ ] Impersonacja SA zamiast direct access (obserwowalność).
- [ ] Zaplanowana rotacja certyfikatu przed `notAfter`.
- [ ] Tokeny v2.0 wymuszone (`accessTokenAcceptedVersion: 2`).

---

## 13. Placeholdery

| Placeholder | Znaczenie | Przykład |
|---|---|---|
| `TENANT_ID` | Directory (tenant) ID w Entra | `9f8e7d6c-aaaa-bbbb-cccc-1234567890ab` |
| `CLIENT_ID` | Application (client) ID App Registration | `a1b2c3d4-1111-2222-3333-444455556666` |
| `PROJECT_ID` | ID projektu GCP | `my-project` |
| `PROJECT_NUMBER` | numer projektu GCP | `123456789012` |
| `REGION` | region GAR | `europe-central2` |
| `entra-pool` | nazwa Workload Identity Pool | — |
| `entra-provider` | nazwa Workload Identity Provider | — |
| `docker-repo` / `maven-repo` | nazwy repozytoriów GAR | — |
| `gar-uploader` | nazwa SA oraz App Role | — |

---

#!/usr/bin/env python3
"""make_assertion.py — client assertion (JWT) podpisana kluczem prywatnym."""
import json, time, uuid, base64, hashlib, argparse
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography import x509

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")

p = argparse.ArgumentParser()
p.add_argument("--tenant", required=True)
p.add_argument("--client-id", required=True)
p.add_argument("--key", required=True)
p.add_argument("--cert", required=True)
a = p.parse_args()

with open(a.key, "rb") as f:
    key = serialization.load_pem_private_key(f.read(), password=None)

with open(a.cert, "rb") as f:
    cert = x509.load_pem_x509_certificate(f.read())
der = cert.public_bytes(serialization.Encoding.DER)
x5t = b64url(hashlib.sha1(der).digest())          # thumbprint SHA-1, base64url

now = int(time.time())
header  = {"alg": "RS256", "typ": "JWT", "x5t": x5t}
payload = {
    "aud": f"https://login.microsoftonline.com/{a.tenant}/oauth2/v2.0/token",
    "iss": a.client_id,
    "sub": a.client_id,
    "jti": str(uuid.uuid4()),
    "nbf": now, "exp": now + 600, "iat": now,
}

si = f"{b64url(json.dumps(header,separators=(',',':')).encode())}." \
     f"{b64url(json.dumps(payload,separators=(',',':')).encode())}"
sig = key.sign(si.encode(), padding.PKCS1v15(), hashes.SHA256())
print(f"{si}.{b64url(sig)}")

*Dokument referencyjny — wzorzec Entra ID (x509) → WIF → GAR. Analogiczny do
`gitlab-oidc-gar-docker.md`.*
