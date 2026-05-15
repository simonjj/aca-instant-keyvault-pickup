# aca-instant-keyvault-pickup

A minimal sample that shows how to get near-instant Azure Key Vault secret rotation
on Azure Container Apps by having the application read the secret directly from
Key Vault using a user-assigned managed identity and caching the value in-process
with a short TTL.

## Why this pattern

Azure Container Apps supports Key Vault secret references on the app's `secrets`
collection. Those references are polled on a background interval (roughly every
30 minutes) and, when a new version is detected, ACA performs a rolling restart
of the replicas on the current revision. That works well for most cases, but it
means rotation latency can be up to 20 to 30 minutes and pods restart.

When you need rotation to land in seconds without restarting pods, bypass the
ACA secret reference and let the application fetch the secret from Key Vault
directly. Cache the value in memory for a small TTL (for example 30 seconds) so
you do not call AKV on every request. On the next TTL tick the app picks up the
new version on its own.

## What this sample deploys

- User-assigned managed identity used by the Container App
- Azure Key Vault (RBAC enabled) seeded with a `demo-secret`
- Azure Container Registry
- Log Analytics workspace
- Azure Container Apps environment and a single Container App
- Role assignments
  - `AcrPull` on the registry to the managed identity
  - `Key Vault Secrets User` on the vault to the managed identity
  - `Key Vault Secrets Officer` on the vault to the deploying user (so you can
    rotate the secret to test pickup)

The Container App runs a small Spring Boot app (Java 21) that exposes three
endpoints:

- `GET /` returns the cached secret value, version, age and seconds until the
  next refresh.
- `GET /refresh` forces a re-read from Key Vault, bypassing the cache.
- `GET /healthz` simple liveness endpoint.

## Prerequisites

- An Azure subscription
- [Azure Developer CLI](https://aka.ms/azd) (`azd`) 1.5.0 or later
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az`)
- JDK 21 and Maven 3.9+ (only needed if you want to build and run the app locally; the container image builds inside Docker)
- Docker (only needed if you want to run the container locally)

## Deploy

```bash
azd auth login
azd up
```

`azd up` will prompt for an environment name, subscription and region, then
provision the infrastructure and build, push and deploy the container image in
one go. When it finishes, it prints the Container App FQDN.

Try the endpoints:

```bash
APP_URL=$(azd env get-values | awk -F= '/AZURE_CONTAINER_APP_FQDN/ {gsub(/"/,"",$2); print $2}')
curl https://$APP_URL/
```

You should see something like:

```json
{
  "status": "ok",
  "secret_name": "demo-secret",
  "secret_value": "hello-from-akv-xxxxxxxx",
  "secret_version": "c0a1...",
  "age_seconds": 1.23,
  "ttl_seconds": 30,
  "seconds_until_refresh": 28.77,
  "vault_url": "https://kv-xxxxxxxx.vault.azure.net"
}
```

## Test rotation pickup

There are two ways the app picks up a rotated secret: the natural TTL expiry
(no app calls needed beyond a request that lands after the TTL window) and a
forced re-read via the `/refresh` endpoint. Below is a walk-through of both,
matching what you would do right after `azd up`.

First, capture the app URL and Key Vault name:

```bash
APP_URL=$(azd env get-values | awk -F= '/AZURE_CONTAINER_APP_FQDN/ {gsub(/"/,"",$2); print $2}')
KV_NAME=$(azd env get-values | awk -F= '/KEY_VAULT_NAME/ {gsub(/"/,"",$2); print $2}')
```

### Option A: automatic pickup via TTL expiry (no app intervention)

This is the path that matters in production. Rotate the secret in AKV, do
nothing on the app side, and confirm the app serves the new value after the
cache window elapses. No restarts, no revisions.

```bash
# 1. Snapshot the current state
curl -s https://$APP_URL/ | jq '{secret_value, secret_version, age_seconds, ttl_seconds}'

# 2. Rotate the secret in AKV
NEW_VALUE="auto-$(date +%s)"
az keyvault secret set --vault-name "$KV_NAME" --name demo-secret --value "$NEW_VALUE" \
  --query '{version:id, updated:attributes.updated}' -o json

# 3. Hit the app immediately. You should still see the OLD value because the
#    in-memory cache has not expired yet.
curl -s https://$APP_URL/ | jq '{secret_value, age_seconds, seconds_until_refresh}'

# 4. Wait just past the TTL window (default 30 seconds).
sleep 35

# 5. Hit the app again. The cached entry is now stale, so the next request
#    re-reads from AKV and you should see the NEW value with age_seconds ~ 0.
curl -s https://$APP_URL/ | jq '{secret_value, secret_version, age_seconds}'
```

Expected output for steps 3 and 5:

```text
# Step 3 (immediate, still cached)
{
  "secret_value": "hello-from-akv-xxxxxxxx",
  "age_seconds": 9.03,
  "seconds_until_refresh": 20.97
}

# Step 5 (after TTL, auto-refreshed)
{
  "secret_value": "auto-1778861571",
  "secret_version": "e3108bbf...",
  "age_seconds": 0.0
}
```

You can also leave a poll running so you can see the transition live:

```bash
while true; do
  curl -s https://$APP_URL/ | jq -c '{value: .secret_value, ver: .secret_version, age: .age_seconds}'
  sleep 3
done
```

### Option B: forced refresh

If you cannot wait for the TTL (for example you want an immediate rotation in
test), hit `/refresh` to bypass the cache and re-read from AKV right away:

```bash
az keyvault secret set --vault-name "$KV_NAME" --name demo-secret --value "rotated-$(date +%s)" >/dev/null
curl -s https://$APP_URL/refresh | jq '{status, secret_value, secret_version, age_seconds}'
```

### PowerShell equivalent (Windows)

```powershell
$URL = "https://" + (azd env get-values | Select-String AZURE_CONTAINER_APP_FQDN | ForEach-Object { ($_ -split '=')[1].Trim('"') })
$KV  = (azd env get-values | Select-String KEY_VAULT_NAME | ForEach-Object { ($_ -split '=')[1].Trim('"') })

az keyvault secret set --vault-name $KV --name demo-secret --value "auto-$(Get-Date -UFormat %s)" --query id -o tsv
Start-Sleep 35
curl.exe -s "$URL/" | ConvertFrom-Json | Select-Object secret_value, secret_version, age_seconds
```

### Tuning the TTL

The default TTL is 30 seconds. Lower it for faster pickup at the cost of more
AKV calls, or raise it if you have many replicas and want to spare AKV. Change
the `secretTtlSeconds` parameter default in `infra/main.bicep`, or override the
`SECRET_TTL_SECONDS` env var on the Container App directly and the next
request after the change will use it.

## Configuration

The Container App is configured with these environment variables, all wired up
by Bicep:

| Variable             | Purpose                                                                 |
| -------------------- | ----------------------------------------------------------------------- |
| `KEY_VAULT_NAME`     | Name of the deployed Key Vault.                                         |
| `SECRET_NAME`        | Secret to read (defaults to `demo-secret`).                             |
| `SECRET_TTL_SECONDS` | In-memory cache TTL. Lower values mean faster pickup, more AKV calls.   |
| `AZURE_CLIENT_ID`    | Client id of the user-assigned managed identity used to call AKV.       |
| `PORT`               | Port the container listens on.                                          |

Tune `secretTtlSeconds` in `infra/main.parameters.json` or via
`azd env set SECRET_TTL_SECONDS 10` and re-run `azd provision`.

## Run locally

Local runs use `DefaultAzureCredential`, so `az login` is enough to authenticate.
You will need at least `Key Vault Secrets User` on the deployed vault (the
deployment grants you `Secrets Officer` which is a superset).

```bash
az login
export KEY_VAULT_NAME=$(azd env get-values | awk -F= '/KEY_VAULT_NAME/ {gsub(/"/,"",$2); print $2}')
export SECRET_NAME=demo-secret
export SECRET_TTL_SECONDS=10

cd src
mvn spring-boot:run
# Visit http://localhost:8080/
```

## Tear down

```bash
azd down --purge --force
```

`--purge` also purges the soft-deleted Key Vault so the next deployment can
reuse the same name.

## Repository layout

```
.
├── azure.yaml                 azd service definition
├── infra/
│   ├── main.bicep             subscription-scope entry point (creates RG)
│   ├── shared.bicep           all resources inside the RG
│   └── main.parameters.json   maps azd env vars to Bicep parameters
└── src/
    ├── pom.xml                Maven build (Spring Boot 3.3, Java 21)
    ├── Dockerfile             multi-stage build: Maven + JDK 21
    ├── .dockerignore
    └── src/main/
        ├── java/com/example/akvpickup/
        │   ├── Application.java
        │   ├── SecretCache.java        thread-safe TTL cache around AKV
        │   └── SecretController.java   /, /refresh, /healthz endpoints
        └── resources/application.properties
```

## Notes and trade-offs

- This pattern trades a small amount of AKV traffic for fast rotation. With a
  30 second TTL each replica reads the vault at most once per 30 seconds.
- The cache lives per process. Restarts and scale-out events will re-read on
  first request.
- For very high request volume or many replicas, consider raising the TTL,
  adding jitter, or using a shared cache (for example Redis) to avoid AKV
  throttling.
- If you cannot change the app, the alternative is to keep using ACA Key Vault
  secret references and pair them with an Event Grid subscription on
  `Microsoft.KeyVault.SecretNewVersionCreated` that calls
  `az containerapp revision restart` on rotation. That keeps ACA as the secret
  integration point but still restarts pods.

## License

MIT
