#!/usr/bin/env bash
# =============================================================================
# preflight.sh — Step 0 of the uap-clc3-2026 exercise.
#
# Checks, for the CURRENT Azure subscription:
#   0. that all resource providers the deployment needs are REGISTERED (Azure
#      for Students subscriptions do NOT pre-register several of them, most
#      notably Microsoft.CognitiveServices — an unregistered RP makes the
#      bicep deployment fail with 'ResourceProviderNotRegistered')
#   1. which regions the subscription is ALLOWED to deploy to (Azure Policy
#      "Allowed resource deployment regions" / "Allowed locations")
#   2. which regions actually offer the services we need (Flex Consumption,
#      Container Apps, Cognitive Services/Foundry, Cosmos DB, Storage, ...)
#   3. the gpt-5-mini quota (TPM) per candidate region
#   4. compute quota per candidate region (informational)
#   5. verdict: RECOMMENDED LOCATION
#   6. GitHub wiring: pushes the local az CLI token store as repo secret
#      AZURE_CLI_TOKENS plus repo variables (RESOURCE_GROUP, LOCATION, ...)
#      into YOUR fork, so the GitHub Actions workflows (.github/workflows/)
#      can deploy without a service principal (students cannot create app
#      registrations in the FH OOe tenant — verified: AADSTS65001-style
#      "Insufficient privileges" from `az ad app create`).
#
# Output: a table of candidate regions, a final RECOMMENDED LOCATION line, and
# (unless --skip-gh) the GitHub secret/variables setup result.
#
# The script is DEFENSIVE on purpose: if a check cannot run (missing role,
# CLI too old, ...), it prints the equivalent MANUAL step (see
# scripts/README.md) and continues. It never hard-fails.
#
# Requirements: Azure CLI (az), jq, GitHub CLI (gh, authenticated) for step 6.
# Run inside the devcontainer or any shell with those installed (on Windows:
# Git Bash, WSL or the devcontainer — .gitattributes keeps *.sh on LF endings):
#   bash scripts/preflight.sh            # full run incl. GitHub wiring
#   bash scripts/preflight.sh --skip-gh  # region/quota checks only
# =============================================================================
set -uo pipefail

MODEL_FAMILY="gpt-5-mini"          # model we deploy in the Foundry project
POLICY_DEF_ID="/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
# regions we probe for model quota first (EU first, then common student regions)
QUOTA_PROBE_ORDER="swedencentral francecentral westeurope northeurope germanywestcentral uksouth eastus2 eastus australiaeast westus westus3"

info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
manual(){ printf '\033[1;35m[MANUAL]\033[0m %s\n' "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "required command '$1' not found"; return 1; }
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# --- 0. login / subscription -------------------------------------------------
info "Step 0: checking Azure CLI login ..."
if ! require_cmd az || ! require_cmd jq; then
  err "Install Azure CLI (https://aka.ms/installazurecli) and jq first."
  exit 1
fi
if ! az account show >/dev/null 2>&1; then
  warn "not logged in — running 'az login' (follow the browser/device-code instructions)"
  az login || { err "az login failed"; exit 1; }
fi
SUB="$(az account show --query id -o tsv)"
SUBNAME="$(az account show --query name -o tsv)"
info "subscription: $SUBNAME ($SUB)"

# display-name -> region-name map (provider APIs return display names)
az account list-locations --query "[].{name: name, displayName: displayName}" -o json > "$TMPD/locations.json" 2>/dev/null \
  || az account list-locations -o json > "$TMPD/locations.json"

# --- 0b. register the resource providers the deployment needs -----------------
# Azure for Students subscriptions do NOT pre-register all resource providers
# (most notably Microsoft.CognitiveServices). An unregistered RP makes the
# bicep deployment fail with 'ResourceProviderNotRegistered', and step 2's
# 'az provider show' region lists are only complete once the RP is registered.
# Registration is async -> register everything first, then wait for 'Registered'.
info "Step 0b: registering required resource providers (Cognitive Services is NOT pre-registered on Azure for Students) ..."
REQUIRED_RPS="Microsoft.App Microsoft.Authorization Microsoft.CognitiveServices Microsoft.ContainerRegistry Microsoft.DocumentDB Microsoft.EventGrid Microsoft.Insights Microsoft.OperationalInsights Microsoft.Resources Microsoft.Storage Microsoft.Web"
for rp in $REQUIRED_RPS; do
  state="$(az provider show --namespace "$rp" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
  if [ "$state" = "Registered" ]; then
    info "  $rp: already registered"
  else
    info "  $rp: $state -> az provider register ..."
    if ! az provider register --namespace "$rp" >/dev/null 2>&1; then
      warn "could not register $rp (needs Contributor or Owner on the subscription — you are Owner on your own student subscription)"
      manual "Register resource providers: portal -> Subscriptions -> your subscription -> Resource providers -> select the RP -> Register; or CLI: az provider register --namespace $rp. Full list: $REQUIRED_RPS. See scripts/README.md section 0."
    fi
  fi
done
# wait for registration (async, can take a few minutes) — poll up to ~5 min
info "waiting for resource provider registration to complete (up to 5 min) ..."
PENDING_RPS="$REQUIRED_RPS"
WAITED=0
while [ -n "$PENDING_RPS" ] && [ "$WAITED" -lt 300 ]; do
  PENDING_RPS=""
  for rp in $REQUIRED_RPS; do
    state="$(az provider show --namespace "$rp" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
    [ "$state" = "Registered" ] || PENDING_RPS="$PENDING_RPS $rp"
  done
  [ -z "$PENDING_RPS" ] && break
  sleep 10; WAITED=$((WAITED + 10))
done
if [ -n "$PENDING_RPS" ]; then
  warn "still not registered after ~5 min:$PENDING_RPS"
  manual "Re-check: az provider show --namespace <NS> --query registrationState -o tsv (portal: Subscriptions -> your subscription -> Resource providers). Registration can take longer — wait a few minutes and re-run this script. See scripts/README.md section 0."
else
  info "all required resource providers are Registered."
fi

# --- 1. allowed regions from Azure Policy ------------------------------------
# POLICY_STATE: restricted = policy list read | none = no such assignment (verified)
#               unknown   = discovery FAILED -> must not claim "all regions allowed"
info "Step 1: reading 'Allowed resource deployment regions' policy assignment ..."
ALLOWED="$TMPD/allowed.txt"; : > "$ALLOWED"
POLICY_STATE="unknown"
if az policy assignment list --scope "/subscriptions/$SUB" -o json > "$TMPD/assignments.json" 2>"$TMPD/assignments.err"; then
  # tolerate both response shapes: fields under .properties (list) or top-level
  jq -r --arg def "$POLICY_DEF_ID" '
    .[] | . as $a
    | select((($a.properties.policyDefinitionId // $a.policyDefinitionId // "") == $def)
             or ((($a.properties.displayName // $a.displayName // "") | test("allowed (resource deployment )?regions|allowed locations"; "i"))))
    | ($a.name // empty)' "$TMPD/assignments.json" > "$TMPD/assignment_names.txt" 2>/dev/null || true
  # Azure enforces ALL matching allowed-location assignments together, so the
  # effective allowed set is the INTERSECTION across assignments (not a union).
  n=0; READ_FAIL=0
  while read -r aname; do
    [ -z "$aname" ] && continue
    n=$((n+1))
    if az policy assignment show --name "$aname" --scope "/subscriptions/$SUB" -o json 2>/dev/null \
       | jq -r '(.properties.parameters // .parameters // {})
                  | (.listOfAllowedLocations.value // .allowedLocations.value // .listOfAllowedLocation.value // empty)
                  | .[]?' 2>/dev/null > "$TMPD/policy_$n.txt" && [ -s "$TMPD/policy_$n.txt" ]; then
      :
    else
      READ_FAIL=1
    fi
  done < "$TMPD/assignment_names.txt"
  if [ "$n" -gt 0 ] && [ "$READ_FAIL" = "0" ]; then
    first=1
    for i in $(seq 1 "$n"); do
      if [ "$first" = "1" ]; then
        cp "$TMPD/policy_$i.txt" "$ALLOWED"; first=0
      else
        comm -12 <(sort -u "$ALLOWED") <(sort -u "$TMPD/policy_$i.txt") > "$TMPD/allowed_new.txt"
        mv "$TMPD/allowed_new.txt" "$ALLOWED"
      fi
    done
    sort -u "$ALLOWED" -o "$ALLOWED"
    POLICY_STATE="restricted"
  elif [ "$n" -gt 0 ]; then
    POLICY_STATE="unknown" # assignment(s) exist but at least one could not be read
  else
    POLICY_STATE="none"    # verified: no allowed-regions assignment at subscription scope
  fi
else
  warn "could not list policy assignments: $(head -c 200 "$TMPD/assignments.err")"
fi
if [ "$POLICY_STATE" = "restricted" ]; then
  sort -u "$ALLOWED" > "$TMPD/allowed_sorted.txt"; mv "$TMPD/allowed_sorted.txt" "$ALLOWED"
  info "allowed regions (policy): $(paste -sd, "$ALLOWED")"
else
  jq -r '.[].name' "$TMPD/locations.json" > "$ALLOWED"
  if [ "$POLICY_STATE" = "none" ]; then
    info "no allowed-regions policy assignment found at subscription scope -> ALL regions are allowed for this subscription."
  else
    warn "allowed-regions policy could NOT be verified -> all regions are used as candidates, but this is UNVERIFIED."
    manual "Confirm your allowed regions manually BEFORE deploying: portal -> Subscriptions -> your subscription -> Policies -> Assignments -> open 'Allowed resource deployment regions' -> read listOfAllowedLocations. See scripts/README.md section 1."
  fi
fi

# --- 2. service availability per region --------------------------------------
info "Step 2: collecting service region availability ..."
provider_locations() { # $1 namespace, $2 resourceType -> region names
  az provider show --namespace "$1" -o json 2>/dev/null \
    | jq -r --slurpfile loc "$TMPD/locations.json" --arg rt "$2" '
        ($loc[0] | map({(.displayName): .name}) | add // {}) as $m
        | .resourceTypes[] | select(.resourceType == $rt) | .locations[] | $m[.] // empty' \
    2>/dev/null || true
}
flex_locations() {
  az functionapp list-flexconsumption-locations --query "[].name" -o json 2>/dev/null \
    | jq -r '.[]?' || true
}
# per-service region lists — the final candidate set is the INTERSECTION of ALL
# of them (a union would let a region pass that lacks e.g. Cosmos or Event Grid)
provider_locations Microsoft.App containerApps           | sort -u > "$TMPD/r_aca.txt"
flex_locations                                           | sort -u > "$TMPD/r_flex.txt"
provider_locations Microsoft.CognitiveServices accounts  | sort -u > "$TMPD/r_ai.txt"
provider_locations Microsoft.DocumentDB databaseAccounts  | sort -u > "$TMPD/r_cosmos.txt"
provider_locations Microsoft.Storage storageAccounts      | sort -u > "$TMPD/r_storage.txt"
provider_locations Microsoft.EventGrid systemTopics       | sort -u > "$TMPD/r_eventgrid.txt"
provider_locations Microsoft.ContainerRegistry registries | sort -u > "$TMPD/r_acr.txt"
provider_locations Microsoft.OperationalInsights workspaces | sort -u > "$TMPD/r_monitor.txt"
provider_locations Microsoft.Web sites                    | sort -u > "$TMPD/r_web.txt"

SERVICE_FILES=(r_aca r_flex r_ai r_cosmos r_storage r_eventgrid r_acr r_monitor r_web)
SERVICE_OK=1
for f in "${SERVICE_FILES[@]}"; do
  if [ ! -s "$TMPD/$f.txt" ]; then
    SERVICE_OK=0
    warn "region list for '$f' is empty — that service's availability is UNKNOWN."
  fi
done
if [ "$SERVICE_OK" = "0" ]; then
  warn "could not query all provider region lists — candidate set below is UNVERIFIED."
  manual "Service regions: compare your allowed regions with https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan (Flex regions), the Container Apps region list, and the Foundry projects region list https://learn.microsoft.com/azure/foundry/reference/region-support. See scripts/README.md section 2."
fi

# intersection: allowed AND every single core service
JQ_ARGS=(--rawfile a "$ALLOWED")
for f in "${SERVICE_FILES[@]}"; do JQ_ARGS+=(--rawfile "${f#r_}" "$TMPD/$f.txt"); done
jq -n "${JQ_ARGS[@]}" '
  def arr($s): $s | split("\n") | map(select(length > 0));
  arr($a) as $A | arr($aca) as $ACA | arr($flex) as $FLEX | arr($ai) as $AI
  | arr($cosmos) as $COSMOS | arr($storage) as $STORAGE | arr($eventgrid) as $EG
  | arr($acr) as $ACR | arr($monitor) as $MON | arr($web) as $WEB
  | [$A[] | select(
      (. as $x | $ACA     | index($x)) and
      (. as $x | $FLEX    | index($x)) and
      (. as $x | $AI      | index($x)) and
      (. as $x | $COSMOS  | index($x)) and
      (. as $x | $STORAGE | index($x)) and
      (. as $x | $EG      | index($x)) and
      (. as $x | $ACR     | index($x)) and
      (. as $x | $MON     | index($x)) and
      (. as $x | $WEB     | index($x)))]' \
  > "$TMPD/candidates.json"
CANDIDATES="$(jq -r '.[]' "$TMPD/candidates.json" 2>/dev/null | paste -sd' ' -)"
if [ -z "${CANDIDATES// }" ]; then
  err "intersection of allowed + service regions is EMPTY."
  manual "No common region. Check scripts/README.md section 2: either request region access (support request) or re-check your allowed-regions policy."
  exit 2
fi
info "candidate regions (allowed ∩ Flex ∩ ContainerApps ∩ AI ∩ core services): $CANDIDATES"

# --- 3. model quota (TPM) per candidate region --------------------------------
info "Step 3: probing $MODEL_FAMILY quota (TPM) in candidate regions (this can take a minute) ..."
: > "$TMPD/quota.tsv"
# probe EU/common regions first, then the rest of the candidates
CAND_SPACE="$(jq -r '.[]' "$TMPD/candidates.json" | tr '\n' ' ')"
PROBE="$(for r in $QUOTA_PROBE_ORDER; do echo "$r"; done; jq -r '.[]' "$TMPD/candidates.json")"
PROBE="$(echo "$PROBE" | awk '!seen[$0]++' | tr '\n' ' ')"
for region in $PROBE; do
  case " $CAND_SPACE " in *" $region "*) ;; *) continue;; esac
  usage="$(az cognitiveservices usage list --location "$region" -o json 2>"$TMPD/usage.err")" || {
    warn "az cognitiveservices usage list failed for $region: $(head -c 150 "$TMPD/usage.err")"
    manual "Model quota for $region: portal -> Quotas, or Foundry portal https://ai.azure.com -> Management center -> Quota. CLI: az cognitiveservices usage list --location $region. See scripts/README.md section 3."
    printf '%s\tn/a\tn/a\tn/a\tQUERY_FAILED\n' "$region" >> "$TMPD/quota.tsv"; continue
  }
  # exact quota entry for OUR deployment SKU only (GlobalStandard.<model>) —
  # never fall back to another SKU's quota; rank by REMAINING capacity
  read -r limit used remaining status < <(jq -r --arg m "OpenAI.GlobalStandard.$MODEL_FAMILY" '
      [.[] | select(.name.value == $m)] as $gs
      | if ($gs | length) == 0 then "n/a\tn/a\tn/a\tUNAVAILABLE"
        else ($gs[0] |
          [((.limit // 0) | tostring),
           ((.currentValue // 0) | tostring),
           (((.limit // 0) - (.currentValue // 0)) | tostring),
           (if ((.limit // 0) - (.currentValue // 0)) > 0 then "OK" else "EXHAUSTED" end)]
          | join("\t"))
        end' <<<"$usage" 2>/dev/null)
  printf '%s\t%s\t%s\t%s\t%s\n' "$region" "${limit:-n/a}" "${used:-n/a}" "${remaining:-n/a}" "${status:-UNAVAILABLE}" >> "$TMPD/quota.tsv"
done

info "subscription quota tier:"
az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.CognitiveServices/quotaTiers?api-version=2025-10-01-preview" -o json 2>/dev/null \
  | jq -r '.value[0].properties.currentTierName // "unknown"' 2>/dev/null \
  || manual "Quota tier: Foundry portal -> Management center -> Quota. See scripts/README.md section 3."

# --- 4. compute quota (informational) -----------------------------------------
info "Step 4: compute quota for the first candidate region (informational) ..."
FIRST="$(head -1 "$TMPD/quota.tsv" | cut -f1)"
az vm list-usage --location "$FIRST" -o table 2>/dev/null | head -20 \
  || manual "Compute quota: portal -> search 'Quotas' -> pick region $FIRST. CLI: az vm list-usage --location $FIRST."

# --- 5. verdict ---------------------------------------------------------------
info "================= PRE-FLIGHT RESULT ================="
printf '%-22s %-10s %-8s %-11s %s\n' "REGION" "LIMIT(KTPM)" "USED" "REMAINING" "STATUS"
while IFS=$'\t' read -r r l u rem st; do printf '%-22s %-10s %-8s %-11s %s\n' "$r" "$l" "$u" "$rem" "$st"; done < "$TMPD/quota.tsv"

# recommend the OK region with the most REMAINING GlobalStandard quota
RECOMMENDED="$(awk -F'\t' '$5=="OK" {print $4 "\t" $1}' "$TMPD/quota.tsv" | sort -s -nr | head -1 | cut -f2)"
if [ -z "$RECOMMENDED" ]; then
  # do NOT print a deployment recommendation — deploying the model would fail
  # and can leave billable resources behind on a zero-quota student subscription
  err "no candidate region has remaining $MODEL_FAMILY GlobalStandard quota > 0 — DO NOT DEPLOY yet."
  manual "Request a quota increase (Foundry portal https://ai.azure.com -> Management center -> Quota -> Request increase; on Azure for Students approval is NOT guaranteed) or pick a region where the Quota page shows remaining > 0 TPM. See scripts/README.md section 3."
  info "======================================================="
  exit 3
fi
printf '\nRECOMMENDED LOCATION: %s\n' "$RECOMMENDED"
info "Use this value as the 'location' parameter of: az deployment sub create --template-file infrastructure/main.bicep --location $RECOMMENDED --parameters location=$RECOMMENDED rgName=rg-clc3-<lastname> --name clc3-2026"
info "If the deployment fails midway: FIRST delete the partial resource group (az group delete --name <rgName> --yes), THEN re-run with a NEW deployment name (--name clc3-2026-r2) — a resource group's location is immutable, so retrying in another region also needs a fresh rgName."
info "If Container Apps environment creation fails with AKSCapacityHeavyUsage, re-run with the next OK region from the table above (fresh rgName + deployment name)."
info "======================================================="

# --- 6. GitHub wiring: repo secret (az token store) + variables ---------------
# Students cannot create service principals in the FH OOe tenant (app
# registration is disabled there), so the workflows authenticate with the
# student's own az CLI token store, stored as the repo secret AZURE_CLI_TOKENS.
# The runner decodes it into $HOME/.azure (see the workflows' login step).
SKIP_GH=0
for a in "$@"; do [ "$a" = "--skip-gh" ] && SKIP_GH=1; done

if [ "$SKIP_GH" = "1" ]; then
  info "Step 6: skipped (--skip-gh). Manual GitHub wiring: scripts/README.md section 6."
elif ! command -v gh >/dev/null 2>&1; then
  warn "Step 6: GitHub CLI (gh) not found — install https://cli.github.com, run 'gh auth login', then re-run this script. Manual steps: scripts/README.md section 6."
elif ! gh auth status >/dev/null 2>&1; then
  warn "Step 6: gh is not authenticated — run 'gh auth login' (device code) and re-run this script. Manual steps: scripts/README.md section 6."
else
  info "Step 6: wiring GitHub Actions in your fork (repo secret + variables) ..."
  REMOTE="$(git remote get-url origin 2>/dev/null || true)"
  # portable owner/repo extraction (BSD sed has no lazy quantifiers)
  REPO="$(printf '%s' "$REMOTE" | sed -E 's#^.*github\.com[/:]##; s#\.git$##')"
  if [ -z "$REMOTE" ] || ! printf '%s' "$REPO" | grep -qxE '[^/]+/[^/]+'; then
    warn "Step 6: origin remote is not a GitHub repo ('$REMOTE'). Point origin at YOUR fork (git remote set-url origin <fork-url>) and re-run, or do the manual steps in scripts/README.md section 6."
  else
    info "GitHub repo: $REPO"
    RG_NAME="${RG_NAME:-}"
    if [ -z "$RG_NAME" ]; then
      if [ -t 0 ]; then
        read -r -p "Resource group name for your deployment [rg-clc3-$USER]: " RG_NAME
      fi
      RG_NAME="${RG_NAME:-rg-clc3-$USER}"
    fi
    LOC="${LOCATION:-$RECOMMENDED}"
    TENANT="$(az account show --query tenantId -o tsv)"

    # --- token store bundle -> secret AZURE_CLI_TOKENS ---
    AZHOME="${AZURE_CONFIG_DIR:-$HOME/.azure}"
    FILES=()
    for f in azureProfile.json msal_token_cache.json accessTokens.json; do
      [ -f "$AZHOME/$f" ] && FILES+=("$f")
    done
    if [ "${#FILES[@]}" -lt 2 ] || ! printf '%s\n' "${FILES[@]}" | grep -qE 'msal_token_cache|accessTokens'; then
      err "Step 6: no az token store found in $AZHOME (need azureProfile.json plus msal_token_cache.json or accessTokens.json). Run 'az login' first, then re-run this script."
    else
      B64="$(tar -czf - -C "$AZHOME" "${FILES[@]}" | base64 | tr -d '\n')"
      gh secret set AZURE_CLI_TOKENS --repo "$REPO" --body "$B64" \
        && info "secret AZURE_CLI_TOKENS set (az CLI token store; refresh by re-running this script — the refresh token lasts ~90 days)"
    fi

    # --- upload token: set once, keep stable across CI redeploys ---
    if gh secret list --repo "$REPO" --jq '.[].name' 2>/dev/null | grep -qx UPLOAD_TOKEN; then
      info "secret UPLOAD_TOKEN already exists — keeping it (CI infra redeploys reuse it). Read the current value for README step 4/7 with: az containerapp secret show --name <containerAppName> --resource-group $RG_NAME --secret-name upload-token --query value -o tsv"
    else
      UPLOAD_TOKEN="$(openssl rand -hex 16)"
      gh secret set UPLOAD_TOKEN --repo "$REPO" --body "$UPLOAD_TOKEN" \
        && info "secret UPLOAD_TOKEN set. SAVE IT — you need it in README step 4 (deploy) and step 7 (upload): $UPLOAD_TOKEN"
    fi

    # --- repo variables consumed by the workflows ---
    gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUB"      && \
    gh variable set AZURE_TENANT_ID       --repo "$REPO" --body "$TENANT"   && \
    gh variable set RESOURCE_GROUP        --repo "$REPO" --body "$RG_NAME"  && \
    gh variable set LOCATION              --repo "$REPO" --body "$LOC"      && \
    gh variable set DEPLOYMENT_NAME       --repo "$REPO" --body "clc3-2026" \
      && info "variables set: AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID, RESOURCE_GROUP=$RG_NAME, LOCATION=$LOC, DEPLOYMENT_NAME=clc3-2026"
    info "The deploy workflows resolve the resource names (function app, storage, ACR, container app, image container) directly from the Azure deployment outputs (az deployment sub show) — no extra repo variables needed."

    info "SECURITY: AZURE_CLI_TOKENS carries YOUR credentials (Owner on your own subscription). Keep the fork PRIVATE and give write access only to yourself — anyone with write access to the repo can read secrets through a workflow. GitHub masks the value in logs."
    info "Next: README step 4 — deploy the infra:"
    info "  az deployment sub create --name clc3-2026 --location $LOC --template-file infrastructure/main.bicep --parameters rgName=$RG_NAME location=$LOC uploadToken=<your UPLOAD_TOKEN>"
    info "(or just push to main of your fork and let the infra-deploy workflow run)"
  fi
fi
