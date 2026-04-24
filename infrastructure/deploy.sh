#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Email Parser — Azure Infrastructure Deployment
# Provisions: Resource Group, Cosmos DB, Storage, Logic App (Consumption),
#             Container Apps, Managed Identity roles, API Connections
# Security: Zero shared keys — all access via managed identity
###############################################################################

# ── Configuration ────────────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-email-parser-rg}"
LOCATION="${LOCATION:-swedencentral}"
COSMOS_ACCOUNT="${COSMOS_ACCOUNT:-email-parser-cosmos}"
COSMOS_DB="email-parser-db"
COSMOS_CONTAINER="emails"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-emailparserstor}"
BLOB_CONTAINER="email-attachments"
LOGIC_APP="${LOGIC_APP:-email-parser-logic}"
CONTAINER_ENV="${CONTAINER_ENV:-email-parser-env}"
CONTAINER_APP="${CONTAINER_APP:-email-parser-app}"

# Content Understanding (optional — set if integrating PDF analysis)
CONTENT_UNDERSTANDING_ENDPOINT="${CONTENT_UNDERSTANDING_ENDPOINT:-}"
CONTENT_UNDERSTANDING_ANALYZER_ID="${CONTENT_UNDERSTANDING_ANALYZER_ID:-}"
CONTENT_UNDERSTANDING_RESOURCE_ID="${CONTENT_UNDERSTANDING_RESOURCE_ID:-}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Email Parser — Azure Infrastructure Deployment             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Config:"
echo "  Resource Group:  $RESOURCE_GROUP"
echo "  Location:        $LOCATION"
echo "  Cosmos Account:  $COSMOS_ACCOUNT"
echo "  Storage Account: $STORAGE_ACCOUNT"
echo "  Logic App:       $LOGIC_APP (Consumption)"
echo "  Container App:   $CONTAINER_APP"
if [ -n "$CONTENT_UNDERSTANDING_ENDPOINT" ]; then
  echo "  Content Understanding: $CONTENT_UNDERSTANDING_ENDPOINT"
  echo "  CU Analyzer ID:  $CONTENT_UNDERSTANDING_ANALYZER_ID"
fi
echo ""

# ── Resource Group ───────────────────────────────────────────────────────────
echo "▸ Creating resource group..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

# ── Cosmos DB (NoSQL API, Serverless) ────────────────────────────────────────
echo "▸ Creating Cosmos DB account (serverless)..."
az cosmosdb create \
  --name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --kind GlobalDocumentDB \
  --capacity-mode Serverless \
  --default-consistency-level Session \
  --locations regionName="$LOCATION" failoverPriority=0 isZoneRedundant=false \
  -o none

echo "▸ Creating Cosmos DB database..."
az cosmosdb sql database create \
  --account-name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$COSMOS_DB" \
  --output none

echo "▸ Creating Cosmos DB container (partition key: /messageId)..."
az cosmosdb sql container create \
  --account-name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --database-name "$COSMOS_DB" \
  --name "$COSMOS_CONTAINER" \
  --partition-key-path "/messageId" \
  --output none

# ── Storage Account (shared key access DISABLED) ────────────────────────────
echo "▸ Creating storage account (shared key access disabled)..."
az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-shared-key-access false \
  --allow-blob-public-access false \
  --output none

echo "▸ Creating blob container..."
az storage container create \
  --name "$BLOB_CONTAINER" \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login \
  --output none

# ── API Connections for Logic App ────────────────────────────────────────────
echo ""
echo "▸ Creating API connections for Logic App..."

SUBSCRIPTION_ID=$(az account show --query id --output tsv)

# Office 365 connection (requires interactive OAuth consent post-deploy)
echo "  ▸ Office 365 connection..."
az resource create \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.Web/connections" \
  --name "office365" \
  --location "$LOCATION" \
  --properties "{
    \"api\": {
      \"id\": \"/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Web/locations/$LOCATION/managedApis/office365\"
    },
    \"displayName\": \"Office 365 - Email Parser\"
  }" \
  --output none

# Azure Blob Storage connection (managed identity)
# MI auth is declared in the Logic App's $connections block, not here.
# This matches the Cosmos DB connection pattern (which works).
echo "  ▸ Azure Blob Storage connection (managed identity)..."
az resource create \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.Web/connections" \
  --name "azureblob" \
  --location "$LOCATION" \
  --properties "{
    \"api\": {
      \"id\": \"/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Web/locations/$LOCATION/managedApis/azureblob\"
    },
    \"displayName\": \"Azure Blob Storage - Email Parser\"
  }" \
  --output none

# Cosmos DB connection (MI auth handled at Logic App $connections level)
echo "  ▸ Cosmos DB connection..."
COSMOS_ENDPOINT=$(az cosmosdb show \
  --name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query documentEndpoint --output tsv)

echo "    Cosmos DB Endpoint: $COSMOS_ENDPOINT"

az resource create \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.Web/connections" \
  --name "cosmosdb" \
  --location "$LOCATION" \
  --properties "{
    \"api\": {
      \"id\": \"/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Web/locations/$LOCATION/managedApis/documentdb\"
    },
    \"displayName\": \"Cosmos DB - Email Parser\"
  }" \
  --output none

# ── Logic App (Consumption) with managed identity ────────────────────────────
echo ""
echo "▸ Creating Logic App (Consumption) with system-assigned managed identity..."

# Build connection resource IDs
OFFICE365_CONN_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/connections/office365"
AZUREBLOB_CONN_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/connections/azureblob"
COSMOSDB_CONN_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/connections/cosmosdb"
OFFICE365_API_ID="/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Web/locations/$LOCATION/managedApis/office365"
AZUREBLOB_API_ID="/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Web/locations/$LOCATION/managedApis/azureblob"
COSMOSDB_API_ID="/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Web/locations/$LOCATION/managedApis/documentdb"

# Read the workflow definition template
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_TEMPLATE="$SCRIPT_DIR/../logic-app/workflow.json"

if [ ! -f "$WORKFLOW_TEMPLATE" ]; then
  echo "ERROR: Workflow definition not found at $WORKFLOW_TEMPLATE"
  exit 1
fi

WORKFLOW_DEFINITION=$(cat "$WORKFLOW_TEMPLATE")

# Replace account name placeholders with actual values
WORKFLOW_DEFINITION=$(echo "$WORKFLOW_DEFINITION" | sed "s/__STORAGE_ACCOUNT__/$STORAGE_ACCOUNT/g; s/__COSMOS_ACCOUNT__/$COSMOS_ACCOUNT/g")

# Replace Content Understanding placeholders (if configured)
if [ -n "$CONTENT_UNDERSTANDING_ENDPOINT" ]; then
  WORKFLOW_DEFINITION=$(echo "$WORKFLOW_DEFINITION" | sed "s|__CONTENT_UNDERSTANDING_ENDPOINT__|$CONTENT_UNDERSTANDING_ENDPOINT|g; s/__CONTENT_UNDERSTANDING_ANALYZER_ID__/$CONTENT_UNDERSTANDING_ANALYZER_ID/g")
fi

# Deploy Logic App Consumption with identity + workflow + MI-auth $connections
# Uses az rest (PUT) so identity and MI-auth connections are created atomically
# (creating without MI first would reject the MI-auth connectionProperties)
PAYLOAD_FILE="$SCRIPT_DIR/.deploy-logic-app-payload.json"
cat > "$PAYLOAD_FILE" <<PAYLOAD
{
  "location": "$LOCATION",
  "identity": {
    "type": "SystemAssigned"
  },
  "properties": {
    "state": "Enabled",
    "definition": $WORKFLOW_DEFINITION,
    "parameters": {
      "\$connections": {
        "value": {
          "office365": {
            "connectionId": "$OFFICE365_CONN_ID",
            "connectionName": "office365",
            "id": "$OFFICE365_API_ID"
          },
          "azureblob": {
            "connectionId": "$AZUREBLOB_CONN_ID",
            "connectionName": "azureblob",
            "connectionProperties": {
              "authentication": {
                "type": "ManagedServiceIdentity"
              }
            },
            "id": "$AZUREBLOB_API_ID"
          },
          "cosmosdb": {
            "connectionId": "$COSMOSDB_CONN_ID",
            "connectionName": "cosmosdb",
            "connectionProperties": {
              "authentication": {
                "type": "ManagedServiceIdentity"
              }
            },
            "id": "$COSMOSDB_API_ID"
          }
        }
      }
    }
  }
}
PAYLOAD

az rest \
  --method PUT \
  --uri "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Logic/workflows/${LOGIC_APP}?api-version=2019-05-01" \
  --body @"$PAYLOAD_FILE" \
  --output none

rm -f "$PAYLOAD_FILE"

LOGIC_APP_PRINCIPAL_ID=$(az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.Logic/workflows" \
  --name "$LOGIC_APP" \
  --query "identity.principalId" --output tsv)

echo "  Logic App MI Principal ID: $LOGIC_APP_PRINCIPAL_ID"

# Grant Logic App managed identity access to API connections
echo "  ▸ Granting Logic App access to API connections..."
TENANT_ID=$(az account show --query tenantId --output tsv)

for CONN_NAME in office365 azureblob cosmosdb; do
  az resource create \
    --resource-group "$RESOURCE_GROUP" \
    --resource-type "Microsoft.Web/connections/accessPolicies" \
    --name "$CONN_NAME/$LOGIC_APP" \
    --properties "{
      \"principal\": {
        \"type\": \"ActiveDirectory\",
        \"identity\": {
          \"tenantId\": \"$TENANT_ID\",
          \"objectId\": \"$LOGIC_APP_PRINCIPAL_ID\"
        }
      }
    }" \
    --output none 2>/dev/null || true
done

# ── Container Apps Environment ───────────────────────────────────────────────
echo ""
echo "▸ Creating Container Apps Environment..."
az containerapp env create \
  --name "$CONTAINER_ENV" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

# ── Container App ────────────────────────────────────────────────────────────
STORAGE_ACCOUNT_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net"

echo "▸ Creating Container App (with placeholder image)..."
az containerapp create \
  --name "$CONTAINER_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$CONTAINER_ENV" \
  --image "ghcr.io/dsanchor/email-parser/email-parser-web:latest" \
  --target-port 8000 \
  --ingress external \
  --min-replicas 0 \
  --max-replicas 3 \
  --system-assigned \
  --env-vars \
    "COSMOS_ENDPOINT=${COSMOS_ENDPOINT}" \
    "COSMOS_DATABASE=${COSMOS_DB}" \
    "COSMOS_CONTAINER=${COSMOS_CONTAINER}" \
    "STORAGE_ACCOUNT_URL=${STORAGE_ACCOUNT_URL}" \
    "STORAGE_CONTAINER=${BLOB_CONTAINER}" \
  --output none

CONTAINER_APP_PRINCIPAL_ID=$(az containerapp identity show \
  --name "$CONTAINER_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query principalId --output tsv)

echo "  Container App MI Principal ID: $CONTAINER_APP_PRINCIPAL_ID"

# ── Role Assignments ────────────────────────────────────────────────────────
echo ""
echo "▸ Configuring role assignments..."

STORAGE_RESOURCE_ID=$(az storage account show \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query id --output tsv)

COSMOS_RESOURCE_ID=$(az cosmosdb show \
  --name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query id --output tsv)

# Logic App MI → Storage Blob Data Contributor
echo "  ▸ Logic App → Storage Blob Data Contributor..."
az role assignment create \
  --assignee-object-id "$LOGIC_APP_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_RESOURCE_ID" \
  --output none 2>/dev/null || echo "    (already assigned)"

# Logic App MI → Cosmos DB Built-in Data Contributor
echo "  ▸ Logic App → Cosmos DB Data Contributor..."
az cosmosdb sql role assignment create \
  --account-name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --role-definition-id "00000000-0000-0000-0000-000000000002" \
  --principal-id "$LOGIC_APP_PRINCIPAL_ID" \
  --scope "/" \
  --output none 2>/dev/null || echo "    (already assigned)"

# Container App MI → Storage Blob Data Reader
echo "  ▸ Container App → Storage Blob Data Reader..."
az role assignment create \
  --assignee-object-id "$CONTAINER_APP_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Reader" \
  --scope "$STORAGE_RESOURCE_ID" \
  --output none 2>/dev/null || echo "    (already assigned)"

# Container App MI → Cosmos DB Built-in Data Reader
echo "  ▸ Container App → Cosmos DB Data Reader..."
az cosmosdb sql role assignment create \
  --account-name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --role-definition-id "00000000-0000-0000-0000-000000000001" \
  --principal-id "$CONTAINER_APP_PRINCIPAL_ID" \
  --scope "/" \
  --output none 2>/dev/null || echo "    (already assigned)"

# Logic App MI → Cognitive Services User (if Content Understanding is configured)
if [ -n "$CONTENT_UNDERSTANDING_RESOURCE_ID" ]; then
  echo "  ▸ Logic App → Cognitive Services User (Content Understanding)..."
  az role assignment create \
    --assignee-object-id "$LOGIC_APP_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Cognitive Services User" \
    --scope "$CONTENT_UNDERSTANDING_RESOURCE_ID" \
    --output none 2>/dev/null || echo "    (already assigned)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Deployment Complete                                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

CONTAINER_APP_URL=$(az containerapp show \
  --name "$CONTAINER_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn --output tsv 2>/dev/null || echo "N/A")

echo "Resources:"
echo "  Resource Group:      $RESOURCE_GROUP"
echo "  Cosmos DB Account:   $COSMOS_ACCOUNT"
echo "  Cosmos DB Endpoint:  ${COSMOS_ENDPOINT:-N/A}"
echo "  Cosmos Database:     $COSMOS_DB"
echo "  Cosmos Container:    $COSMOS_CONTAINER (partition: /messageId)"
echo "  Storage Account:     $STORAGE_ACCOUNT (shared key access DISABLED)"
echo "  Blob Container:      $BLOB_CONTAINER"
echo "  Logic App:           $LOGIC_APP (Consumption)"
echo "  Container App:       $CONTAINER_APP"
echo "  Container App URL:   https://$CONTAINER_APP_URL"
echo ""
echo "Managed Identity Roles:"
echo "  Logic App MI ($LOGIC_APP_PRINCIPAL_ID):"
echo "    → Storage Blob Data Contributor on $STORAGE_ACCOUNT"
echo "    → Cosmos DB Built-in Data Contributor (00000000-0000-0000-0000-000000000002)"
if [ -n "$CONTENT_UNDERSTANDING_RESOURCE_ID" ]; then
  echo "    → Cognitive Services User on Content Understanding resource"
fi
echo "  Container App MI ($CONTAINER_APP_PRINCIPAL_ID):"
echo "    → Storage Blob Data Reader on $STORAGE_ACCOUNT"
echo "    → Cosmos DB Built-in Data Reader (00000000-0000-0000-0000-000000000001)"
echo ""
echo "Security:"
echo "  ✓ Storage shared key access: DISABLED"
echo "  ✓ All service auth: Managed Identity only"
echo "  ✓ Zero connection strings"
echo ""
echo "⚠  Next steps:"
echo "  1. Authorize the Office 365 API connection in the Azure Portal:"
echo "     Resource Group → API Connections → office365 → Edit API connection → Authorize"
echo "  2. Push web-app changes to main branch to trigger GitHub Actions build"
echo "     (or trigger manually via workflow_dispatch)"
echo "  3. After GH Actions builds the image, update the Container App:"
echo "     az containerapp update \\"
echo "       --resource-group $RESOURCE_GROUP \\"
echo "       --name $CONTAINER_APP \\"
echo "       --image ghcr.io/<owner>/<repo>/email-parser-web:latest"
