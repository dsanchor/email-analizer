#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Email Analyzer — Azure Function Deployment
# Provisions: Function App (Linux, Python 3.11, Consumption)
#             Managed Identity, role assignments (Cosmos DB + Storage)
# Purpose: Cosmos DB change feed processor for classified emails
# Security: Zero shared keys — managed identity for ALL access
#           (Cosmos DB and Storage Account)
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

# Uses managed identity for storage access — no shared keys required.
# This avoids 403 errors from Azure Policy enforcing allowSharedKeyAccess=false.
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

# Pre-create the file share that Azure Functions needs for its content.
# Using 'az storage share-rm create' which goes through ARM (RBAC-based),
# NOT the storage data plane — so it works even when shared key access is disabled.
CONTENT_SHARE="${FUNCTION_APP}"
echo "  Pre-creating content file share '$CONTENT_SHARE' via ARM API..."
if ! az storage share-rm show \
  --storage-account "$FUNCTION_STORAGE" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTENT_SHARE" &>/dev/null; then
  az storage share-rm create \
    --storage-account "$FUNCTION_STORAGE" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTENT_SHARE" \
    --quota 1 \
    --output none
  echo "  ✓ Content share created"
else
  echo "  (content share already exists)"
fi

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

# ── Function App (Consumption Plan, Linux, Python 3.11) ──────────────────────
echo ""
echo "▸ Creating Azure Function App (Consumption, Linux, Python 3.11)..."

echo "  Checking if function app exists..."
if ! az functionapp show \
  --name "$FUNCTION_APP" \
  --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "  Function app not found, creating..."
  az functionapp create \
    --name "$FUNCTION_APP" \
    --resource-group "$RESOURCE_GROUP" \
    --consumption-plan-location "$LOCATION" \
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
# WEBSITE_CONTENTSHARE points to the pre-created file share.
# We also remove any leftover AzureWebJobsStorage connection string.
az functionapp config appsettings set \
  --name "$FUNCTION_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --settings \
    "COSMOS_ENDPOINT=$COSMOS_ENDPOINT" \
    "COSMOS_DATABASE=$COSMOS_DB" \
    "COSMOS_CONTAINER=$COSMOS_CONTAINER" \
    "COSMOS_CONNECTION__accountEndpoint=$COSMOS_ENDPOINT" \
    "AzureWebJobsStorage__accountName=$FUNCTION_STORAGE" \
    "WEBSITE_CONTENTSHARE=$FUNCTION_APP" \
    "WEBSITE_CONTENTAZUREFILECONNECTIONSTRING__accountName=$FUNCTION_STORAGE" \
  --output none

# Remove the legacy connection string if it exists (from prior deployments)
az functionapp config appsettings delete \
  --name "$FUNCTION_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --setting-names "AzureWebJobsStorage" \
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
