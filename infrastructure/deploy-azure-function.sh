#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Email Analyzer — Azure Function Deployment
# Provisions: Function App (Linux, Python 3.11, App Service Plan B1)
#             Managed Identity, role assignments (Cosmos DB + Storage)
# Purpose: Cosmos DB change feed processor for classified emails
# Security: Zero shared keys — managed identity for ALL access
#           (Cosmos DB and Storage Account)
#
# NOTE: Uses App Service Plan (B1) instead of Consumption plan because
#       Azure Policy enforces allowSharedKeyAccess=false on storage accounts.
#       Consumption plan REQUIRES file shares created via shared keys,
#       which fails under this policy. App Service Plan stores code locally,
#       avoiding the file share requirement entirely.
###############################################################################

# ── Configuration ────────────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-email-analyzer-rg}"
LOCATION="${LOCATION:-swedencentral}"
COSMOS_ACCOUNT="${COSMOS_ACCOUNT:-email-analyzer-cosmos}"
COSMOS_DB="email-analyzer-db"
COSMOS_CONTAINER="emails"
LEASE_CONTAINER="leases"
FUNCTION_APP="${FUNCTION_APP:-email-analyzer-func}"
FUNCTION_STORAGE="${FUNCTION_STORAGE:-emailanalyzerfuncstor}"
APP_SERVICE_PLAN="${APP_SERVICE_PLAN:-email-analyzer-func-plan}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Email Analyzer — Azure Function Deployment                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Config:"
echo "  Resource Group:        $RESOURCE_GROUP"
echo "  Location:              $LOCATION"
echo "  Cosmos Account:        $COSMOS_ACCOUNT"
echo "  Function App:          $FUNCTION_APP"
echo "  Function Storage:      $FUNCTION_STORAGE"
echo "  App Service Plan:      $APP_SERVICE_PLAN"
echo "  Cosmos Database:       $COSMOS_DB"
echo "  Cosmos Container:      $COSMOS_CONTAINER"
echo "  Lease Container:       $LEASE_CONTAINER"
echo ""

# ── Verify Prerequisites ─────────────────────────────────────────────────────
echo "▸ Verifying prerequisites..."

# Check if resource group exists
if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  echo "ERROR: Resource group $RESOURCE_GROUP does not exist. Run infrastructure/deploy.sh first."
  exit 1
fi

# Check if Cosmos account exists
if ! az cosmosdb show --name "$COSMOS_ACCOUNT" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "ERROR: Cosmos DB account $COSMOS_ACCOUNT does not exist. Run infrastructure/deploy.sh first."
  exit 1
fi

# Get Cosmos endpoint
COSMOS_ENDPOINT=$(az cosmosdb show \
  --name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query documentEndpoint --output tsv)

echo "  ✓ Resource group exists: $RESOURCE_GROUP"
echo "  ✓ Cosmos DB exists: $COSMOS_ACCOUNT"
echo "  ✓ Cosmos endpoint: $COSMOS_ENDPOINT"

# ── Storage Account for Function App ─────────────────────────────────────────
echo ""
echo "▸ Creating dedicated storage account for Function App internal storage..."

# Storage is needed for WebJobs state (triggers, timers, etc.) but NOT for
# file shares — App Service Plan stores code locally on the VM.
if ! az storage account show \
  --name "$FUNCTION_STORAGE" \
  --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  az storage account create \
    --name "$FUNCTION_STORAGE" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --output none
else
  echo "  (storage account already exists)"
fi

FUNCTION_STORAGE_ID=$(az storage account show \
  --name "$FUNCTION_STORAGE" \
  --resource-group "$RESOURCE_GROUP" \
  --query id --output tsv)

# ── Create Lease Container in Cosmos DB ──────────────────────────────────────
echo ""
echo "▸ Creating lease container in Cosmos DB..."

if ! az cosmosdb sql container show \
  --account-name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --database-name "$COSMOS_DB" \
  --name "$LEASE_CONTAINER" &>/dev/null; then
  az cosmosdb sql container create \
    --account-name "$COSMOS_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --database-name "$COSMOS_DB" \
    --name "$LEASE_CONTAINER" \
    --partition-key-path "/id" \
    --output none
else
  echo "  (lease container already exists)"
fi

# ── App Service Plan (Linux, B1) ─────────────────────────────────────────────
echo ""
echo "▸ Creating App Service Plan (Linux, B1)..."

# App Service Plan avoids the Consumption plan's hard requirement for file shares
# created via shared keys. B1 stores function code on the local VM filesystem.
if ! az appservice plan show \
  --name "$APP_SERVICE_PLAN" \
  --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  az appservice plan create \
    --name "$APP_SERVICE_PLAN" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku B1 \
    --is-linux \
    --output none
  echo "  ✓ App Service Plan created (B1, Linux)"
else
  echo "  (App Service Plan already exists)"
fi

# ── Function App (App Service Plan, Linux, Python 3.11) ──────────────────────
echo ""
echo "▸ Creating Azure Function App (App Service Plan, Linux, Python 3.11)..."

echo "  Checking if function app exists..."
if ! az functionapp show \
  --name "$FUNCTION_APP" \
  --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "  Function app not found, creating..."
  az functionapp create \
    --name "$FUNCTION_APP" \
    --resource-group "$RESOURCE_GROUP" \
    --plan "$APP_SERVICE_PLAN" \
    --runtime python \
    --runtime-version 3.11 \
    --os-type Linux \
    --functions-version 4 \
    --storage-account "$FUNCTION_STORAGE" \
    --assign-identity '[system]' \
    --output none
  echo "  ✓ Function app created"
else
  echo "  (function app already exists)"
fi

# Enable system-assigned managed identity (if not already enabled)
az functionapp identity assign \
  --name "$FUNCTION_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --output none

FUNCTION_PRINCIPAL_ID=$(az functionapp identity show \
  --name "$FUNCTION_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query principalId --output tsv)

echo "  Function App MI Principal ID: $FUNCTION_PRINCIPAL_ID"

# ── Configure App Settings ───────────────────────────────────────────────────
echo ""
echo "▸ Configuring Function App settings..."

# Switch storage to managed identity AFTER creation.
# AzureWebJobsStorage__accountName tells the runtime to use MI instead of connection string.
# No WEBSITE_CONTENTSHARE or file connection string needed — App Service Plan
# stores code locally, not on Azure Files.
az functionapp config appsettings set \
  --name "$FUNCTION_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --settings \
    "COSMOS_ENDPOINT=$COSMOS_ENDPOINT" \
    "COSMOS_DATABASE=$COSMOS_DB" \
    "COSMOS_CONTAINER=$COSMOS_CONTAINER" \
    "COSMOS_CONNECTION__accountEndpoint=$COSMOS_ENDPOINT" \
    "AzureWebJobsStorage__accountName=$FUNCTION_STORAGE" \
  --output none

# Remove legacy settings from prior Consumption plan deployments
az functionapp config appsettings delete \
  --name "$FUNCTION_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --setting-names "AzureWebJobsStorage" "WEBSITE_CONTENTSHARE" "WEBSITE_CONTENTAZUREFILECONNECTIONSTRING__accountName" \
  --output none 2>/dev/null || true

# ── Role Assignments ─────────────────────────────────────────────────────────

# -- Storage roles for Function App MI --
echo ""
echo "▸ Assigning Storage roles to Function App MI..."

# Storage Blob Data Owner — read/write blobs (function state, host.json, etc.)
echo "  Assigning Storage Blob Data Owner..."
az role assignment create \
  --assignee "$FUNCTION_PRINCIPAL_ID" \
  --role "Storage Blob Data Owner" \
  --scope "$FUNCTION_STORAGE_ID" \
  --output none 2>/dev/null || echo "  (Storage Blob Data Owner already assigned)"

# Storage Account Contributor — manage file shares
echo "  Assigning Storage Account Contributor..."
az role assignment create \
  --assignee "$FUNCTION_PRINCIPAL_ID" \
  --role "Storage Account Contributor" \
  --scope "$FUNCTION_STORAGE_ID" \
  --output none 2>/dev/null || echo "  (Storage Account Contributor already assigned)"

# Storage Queue Data Contributor — manage queues (used by triggers)
echo "  Assigning Storage Queue Data Contributor..."
az role assignment create \
  --assignee "$FUNCTION_PRINCIPAL_ID" \
  --role "Storage Queue Data Contributor" \
  --scope "$FUNCTION_STORAGE_ID" \
  --output none 2>/dev/null || echo "  (Storage Queue Data Contributor already assigned)"

# Storage File Data Privileged Contributor — manage file shares (function code)
echo "  Assigning Storage File Data Privileged Contributor..."
az role assignment create \
  --assignee "$FUNCTION_PRINCIPAL_ID" \
  --role "Storage File Data Privileged Contributor" \
  --scope "$FUNCTION_STORAGE_ID" \
  --output none 2>/dev/null || echo "  (Storage File Data Privileged Contributor already assigned)"

# Storage Table Data Contributor — manage tables (timer triggers, etc.)
echo "  Assigning Storage Table Data Contributor..."
az role assignment create \
  --assignee "$FUNCTION_PRINCIPAL_ID" \
  --role "Storage Table Data Contributor" \
  --scope "$FUNCTION_STORAGE_ID" \
  --output none 2>/dev/null || echo "  (Storage Table Data Contributor already assigned)"

# -- Cosmos DB role for Function App MI --
echo ""
echo "▸ Assigning Cosmos DB Built-in Data Contributor role to Function App MI..."

# Function App MI needs write access to update documents after processing
# Cosmos DB Built-in Data Contributor role ID: 00000000-0000-0000-0000-000000000002
if ! az cosmosdb sql role assignment exists \
  --account-name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --role-definition-id "00000000-0000-0000-0000-000000000002" \
  --principal-id "$FUNCTION_PRINCIPAL_ID" \
  --scope "/" &>/dev/null 2>&1; then
  az cosmosdb sql role assignment create \
    --account-name "$COSMOS_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --role-definition-id "00000000-0000-0000-0000-000000000002" \
    --principal-id "$FUNCTION_PRINCIPAL_ID" \
    --scope "/" \
    --output none
else
  echo "  (role already assigned)"
fi

# ── Deploy Function Code ─────────────────────────────────────────────────────
echo ""
echo "▸ Deploying function code..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTION_DIR="$SCRIPT_DIR/../azure-function"

if [ ! -d "$FUNCTION_DIR" ]; then
  echo "ERROR: Function code directory not found at $FUNCTION_DIR"
  exit 1
fi

# Check if Azure Functions Core Tools is installed
if ! command -v func &>/dev/null; then
  echo ""
  echo "⚠  Azure Functions Core Tools not found."
  echo "   Install from: https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local"
  echo ""
  echo "   To deploy manually, run:"
  echo "     cd $FUNCTION_DIR"
  echo "     func azure functionapp publish $FUNCTION_APP"
  echo ""
  echo "Skipping code deployment..."
else
  cd "$FUNCTION_DIR"
  func azure functionapp publish "$FUNCTION_APP" --python
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Deployment Complete                                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Resources:"
echo "  Resource Group:      $RESOURCE_GROUP"
echo "  App Service Plan:    $APP_SERVICE_PLAN (B1, Linux)"
echo "  Function App:        $FUNCTION_APP"
echo "  Function Storage:    $FUNCTION_STORAGE"
echo "  Cosmos DB Account:   $COSMOS_ACCOUNT"
echo "  Cosmos DB Endpoint:  $COSMOS_ENDPOINT"
echo "  Cosmos Database:     $COSMOS_DB"
echo "  Cosmos Container:    $COSMOS_CONTAINER"
echo "  Lease Container:     $LEASE_CONTAINER"
echo ""
echo "Managed Identity Roles:"
echo "  Function App MI ($FUNCTION_PRINCIPAL_ID):"
echo "    → Cosmos DB Built-in Data Contributor (00000000-0000-0000-0000-000000000002)"
echo "    → Storage Blob Data Owner"
echo "    → Storage Account Contributor"
echo "    → Storage Queue Data Contributor"
echo "    → Storage File Data Privileged Contributor"
echo "    → Storage Table Data Contributor"
echo ""
echo "Security:"
echo "  ✓ App Service Plan (B1) — no file share dependency, avoids shared key issues"
echo "  ✓ Function App uses managed identity for Cosmos DB access"
echo "  ✓ Function App uses managed identity for Storage access"
echo "  ✓ Zero connection strings — fully managed identity based"
echo ""
echo "Function Trigger:"
echo "  Cosmos DB change feed on $COSMOS_DB/$COSMOS_CONTAINER"
echo "  Processes emails when last status = 'Email classified'"
echo ""
echo "Monitoring:"
echo "  az functionapp logs tail --name $FUNCTION_APP --resource-group $RESOURCE_GROUP"
echo ""
