# Pre-flight checks — manual instructions (source of truth)

Run `bash scripts/preflight.sh` first. It automates everything below, but if a
check fails (permissions, CLI version, ...) follow the manual steps in this
file. **These manual steps are the authoritative version** — the script only
saves you typing.

You need: Azure CLI (`az`, https://aka.ms/installazurecli) logged in to your
**Azure for Students** subscription (`az login`, then
`az account set --subscription <id>`), and the Azure portal
(https://portal.azure.com) plus the Foundry portal (https://ai.azure.com).

On **Windows** run the script from Git Bash (ships with Git for Windows), WSL,
or the devcontainer: `bash scripts/preflight.sh`. The repo's `.gitattributes`
forces LF line endings for `*.sh`, so the script behaves the same on Windows and
Linux/macOS — bash fails on CRLF, so do not convert the file. (If you cloned
before `.gitattributes` existed and the script already has CRLF endings,
re-check it out: `git rm --cached scripts/preflight.sh && git checkout -- scripts/preflight.sh`.)

## 0. Register the resource providers the deployment needs

Azure for Students subscriptions do **not** pre-register all resource providers —
most notably **Microsoft.CognitiveServices** (Foundry). An unregistered resource
provider makes the bicep deployment fail with `ResourceProviderNotRegistered`.

`preflight.sh` step 0b registers these automatically and waits until every one
shows `Registered`:

```
Microsoft.App  Microsoft.Authorization  Microsoft.CognitiveServices
Microsoft.ContainerRegistry  Microsoft.DocumentDB  Microsoft.EventGrid
Microsoft.Insights  Microsoft.OperationalInsights  Microsoft.Resources
Microsoft.Storage  Microsoft.Web
```

- **CLI (manual equivalent):**
  ```bash
  for rp in Microsoft.App Microsoft.Authorization Microsoft.CognitiveServices \
            Microsoft.ContainerRegistry Microsoft.DocumentDB Microsoft.EventGrid \
            Microsoft.Insights Microsoft.OperationalInsights Microsoft.Resources \
            Microsoft.Storage Microsoft.Web; do
    az provider register --namespace "$rp"   # async — poll until Registered:
    az provider show --namespace "$rp" --query registrationState -o tsv
  done
  ```
- **Portal:** Subscriptions → your subscription → **Resource providers** →
  select each provider above → **Register** (wait until the state is `Registered`;
  this can take a few minutes).

## 1. Which regions are you allowed to deploy to?

Azure for Students subscriptions have an Azure Policy assignment that restricts
regions. The set is **different per student subscription**.

- **Portal:** search `Subscriptions` → select your subscription → left menu
  **Policies** → **Assignments** → open the assignment named
  **"Allowed resource deployment regions"** (or "Allowed locations") → under
  **Parameters** read `listOfAllowedLocations` — that list is your allowed
  region set. If there is no such assignment, all regions are allowed.
- **CLI:**
  ```bash
  SUB=$(az account show --query id -o tsv)
  az policy assignment list --scope "/subscriptions/$SUB" -o json \
    | jq -r '.[] | . as $a
             | select((($a.properties.policyDefinitionId // $a.policyDefinitionId // "") == "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c")
                      or ((($a.properties.displayName // $a.displayName // "") | test("allowed"; "i"))))
             | ($a.name // empty)'
  # then, per assignment name (note: if SEVERAL assignments match, the effective
  # allowed set is the INTERSECTION of all their location lists):
  az policy assignment show --name <name> --scope "/subscriptions/$SUB" -o json \
    | jq -r '(.properties.parameters // .parameters // {})
             | (.listOfAllowedLocations.value // .allowedLocations.value // .listOfAllowedLocation.value // empty) | .[]?'
  ```

## 2. Which of those regions actually offer the services we need?

You need ONE region that supports all of: Flex Consumption (Functions), Container
Apps, Cognitive Services/Foundry (AIServices + project), Cosmos DB, Storage,
Event Grid, Container Registry, Monitor.

- **CLI:**
  ```bash
  az functionapp list-flexconsumption-locations --query "[].name" -o tsv   # Flex Consumption regions
  az provider show --namespace Microsoft.App --query "resourceTypes[?resourceType=='containerApps'].locations" -o tsv
  az provider show --namespace Microsoft.CognitiveServices --query "resourceTypes[?resourceType=='accounts'].locations" -o tsv
  ```
  (Provider APIs print display names, e.g. "West Europe" — convert with
  `az account list-locations --query "map(&{name:name, displayName:displayName})"`.)
- **Docs:** Flex Consumption regions and Foundry project regions:
  https://learn.microsoft.com/azure/foundry/reference/region-support

Common regions that work on many student subscriptions: `swedencentral`,
`francecentral`, `eastus2`; `westeurope` works only if your policy allows it.
If your allowed set contains no Foundry-capable region at all, open a
region-access support request (portal → Help + support) — see
https://learn.microsoft.com/answers/questions/5916405.

## 3. Do you have model quota (gpt-5-mini TPM) in that region?

Quota is per subscription + region + model. On student subscriptions the default
is often **0 TPM**, and increase requests are frequently denied.

- **CLI:**
  ```bash
  az cognitiveservices usage list --location <region> -o json \
    | jq '[.[] | select(.name.value | test("gpt-5-mini"; "i")) | {name: .name.value, used: .currentValue, limit: .limit}]'
  ```
  (Requires `Reader`/`Cognitive Services Usages Reader` on the subscription —
  you are Owner on your own student subscription.)
  Subscription quota tier:
  ```bash
  az rest --method get --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/providers/Microsoft.CognitiveServices/quotaTiers?api-version=2025-10-01-preview"
  ```
- **Foundry portal (per-region model quota):** https://ai.azure.com →
  **Management center** → **Quota** → find gpt-5-mini in your candidate region.
  Alternative: **Models + endpoints** → **Deploy model** → gpt-5-mini → the
  region dropdown shows available quota per region.
- If quota is **0**: click **Request quota increase** in the Quota page (approval
  on student subscriptions is not guaranteed), **or** choose a different allowed
  region where the Quota page shows > 0 TPM (commonly `swedencentral`, `eastus2`).

## 4. Compute quota (informational)

- **Portal:** search `Quotas` → **Quotas** blade → filter by region.
- **CLI:** `az vm list-usage --location <region> -o table`

(Flex Consumption and Container Apps do not consume VM core quota, so this is
informational only.)

## 5. Pick the location and continue

Choose one region that is in your allowed list AND supports all services AND has
gpt-5-mini quota > 0. Use it as the single `location` for the whole deployment:

```bash
az deployment sub create --template-file infrastructure/main.bicep \
  --location <your-region> --parameters rgName=rg-clc3-<lastname> location=<your-region>
```

If the deployment **fails midway** (e.g. Container Apps environment creation
fails with `AKSCapacityHeavyUsage` — region capacity exhaustion):

1. **Delete the partial resource group first** — a resource group's location is
   immutable, so you cannot just change the region on a retry:
   ```bash
   az group delete --name <rgName> --yes --no-wait
   # wait until it is gone: az group show --name <rgName>  (should 404)
   ```
2. **Re-run with a fresh resource-group name AND a new deployment name** (the
   old deployment record still references the old group):
   ```bash
   az deployment sub create --template-file infrastructure/main.bicep \
     --location <next-candidate-region> --name clc3-2026-r2 \
     --parameters rgName=rg-clc3-<lastname>-r2 location=<next-candidate-region>
   ```
   Pick the next candidate region from the `preflight.sh` result table (the one
   with the most remaining gpt-5-mini GlobalStandard quota).

## 6. GitHub wiring (manual equivalent of `preflight.sh` step 6)

`preflight.sh` sets these automatically. If you ran it with `--skip-gh`, do this by hand
(requires the GitHub CLI, `gh auth login` once, and your fork as the `origin` remote):

```bash
REPO=<owner>/<fork>          # e.g. gh repo view --json nameWithOwner -q .nameWithOwner
SUB=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)
RG_NAME=rg-clc3-<lastname>
LOC=<RECOMMENDED LOCATION from preflight output>

# 1. az CLI token store as repo secret (students cannot create SPs in the FH OOe
#    tenant — `az ad app create` fails with "Insufficient privileges" there)
AZHOME="${AZURE_CONFIG_DIR:-$HOME/.azure}"
FILES="azureProfile.json"
[ -f "$AZHOME/msal_token_cache.json" ] && FILES="$FILES msal_token_cache.json"
[ -f "$AZHOME/accessTokens.json" ] && FILES="$FILES accessTokens.json"
tar -czf - -C "$AZHOME" $FILES | base64 | tr -d '\n' | gh secret set AZURE_CLI_TOKENS --repo "$REPO" --body-file -

# 2. upload token (set once; reused by CI so it does not rotate)
gh secret set UPLOAD_TOKEN --repo "$REPO" --body "$(openssl rand -hex 16)"   # save the printed value!

# 3. variables used by .github/workflows/
gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUB"
gh variable set AZURE_TENANT_ID       --repo "$REPO" --body "$TENANT"
gh variable set RESOURCE_GROUP        --repo "$REPO" --body "$RG_NAME"
gh variable set LOCATION              --repo "$REPO" --body "$LOC"
gh variable set DEPLOYMENT_NAME       --repo "$REPO" --body "clc3-2026"
# The deploy workflows resolve the resource names (function app, storage, ACR,
# container app, image container) from the Azure deployment outputs themselves
# (`az deployment sub show`) — no extra variables to set.
```

The workflows decode `AZURE_CLI_TOKENS` into `$HOME/.azure` on the runner (see the "Login to Azure"
step in each workflow) — the secret never appears in logs (GitHub masks it). Re-run this when the
token expires (~90 days) or after `az login` on a different account.

Keep the fork **private**: the secret carries your own subscription credentials (Owner on your own
subscription), and anyone with write access to the repo can read secrets through a workflow.
