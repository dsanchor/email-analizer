#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Email Analyzer — Azure Function Deployment
# Provisions: Function App (Linux, Python 3.11, Consumption)
#             Managed Identity, Cosmos DB role assignments, Storage account
# Purpose: Cosmos DB change feed processor for classified emails
# Security: Zero shared keys — managed identity for all Cosmos DB access
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

# Function App needs a storage account for its internal state (host.json, triggers, etc.)
# Since the main storage account has shared key access disabled, we create a dedicated one
# for the Function App that allows shared key access (required by Functions runtime)
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
    --allow-shared-key-access true \
    --allow-blob-public-access false \
    --output none
else
  echo "  (storage account already exists)"
fi

FUNCTION_STORAGE_CONNECTION=$(az storage account show-connection-string \
  --name "$FUNCTION_STORAGE" \
  --resource-group "$RESOURCE_GROUP" \
  --query connectionString --output tsv)

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

if ! az functionapp show \
  --name "$FUNCTION_APP" \
  --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  az functionapp create \
    --name "$FUNCTION_APP" \
    --resource-group "$RESOURCE_GROUP" \
    --consumption-plan-location "$LOCATION" \
    --runtime python \
    --runtime-version 3.11 \
    --os-type Linux \
    --functions-version 4 \
    --storage-account "$FUNCTION_STORAGE" \
    --assign-identity [system] \
    --output none
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

az functionapp config appsettings set \
  --name "$FUNCTION_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --settings \
    "COSMOS_ENDPOINT=$COSMOS_ENDPOINT" \
    "COSMOS_DATABASE=$COSMOS_DB" \
    "COSMOS_CONTAINER=$COSMOS_CONTAINER" \
    "COSMOS_CONNECTION__accountEndpoint=$COSMOS_ENDPOINT" \
    "AzureWebJobsStorage=$FUNCTION_STORAGE_CONNECTION" \
  --output none

# ── Role Assignments ─────────────────────────────────────────────────────────
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
echo ""
echo "Security:"
echo "  ✓ Function App uses managed identity for Cosmos DB access"
echo "  ✓ Zero connection strings (except Function internal storage)"
echo ""
echo "Function Trigger:"
echo "  Cosmos DB change feed on $COSMOS_DB/$COSMOS_CONTAINER"
echo "  Processes emails when last status = 'Email classified'"
echo ""
echo "Monitoring:"
echo "  az functionapp logs tail --name $FUNCTION_APP --resource-group $RESOURCE_GROUP"
echo ""
