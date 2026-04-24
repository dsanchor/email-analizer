#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Email Parser — Logic App Workflow Redeploy
# Updates ONLY the Logic App workflow definition on an existing Consumption
# Logic App. Does NOT create any resources (no RG, Cosmos, Storage, etc.).
# Safe to run repeatedly — idempotent PUT to the ARM endpoint.
###############################################################################

# ── Configuration (same variables as deploy.sh) ──────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-email-parser-rg}"
LOCATION="${LOCATION:-swedencentral}"
LOGIC_APP="${LOGIC_APP:-email-parser-logic}"
COSMOS_ACCOUNT="${COSMOS_ACCOUNT:-email-parser-cosmos}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-emailparserstor}"

# Content Understanding (optional — set if integrating PDF analysis)
CONTENT_UNDERSTANDING_ENDPOINT="${CONTENT_UNDERSTANDING_ENDPOINT:-}"
CONTENT_UNDERSTANDING_ANALYZER_ID="${CONTENT_UNDERSTANDING_ANALYZER_ID:-}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Email Parser — Logic App Workflow Redeploy                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Config:"
echo "  Resource Group:  $RESOURCE_GROUP"
echo "  Location:        $LOCATION"
echo "  Logic App:       $LOGIC_APP (Consumption)"
echo ""

# ── Validate the Logic App exists ────────────────────────────────────────────
echo "▸ Verifying Logic App exists..."
if ! az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.Logic/workflows" \
  --name "$LOGIC_APP" \
  --query "name" --output tsv > /dev/null 2>&1; then
  echo "ERROR: Logic App '$LOGIC_APP' not found in resource group '$RESOURCE_GROUP'."
  echo "       Run infrastructure/deploy.sh first to create all resources."
  exit 1
fi

# ── Look up subscription ID ─────────────────────────────────────────────────
SUBSCRIPTION_ID=$(az account show --query id --output tsv)

# ── Build connection resource IDs ────────────────────────────────────────────
# Same pattern as deploy.sh — connection IDs and managed API IDs
OFFICE365_CONN_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/connections/office365"
AZUREBLOB_CONN_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/connections/azureblob"
COSMOSDB_CONN_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/connections/cosmosdb"
OFFICE365_API_ID="/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Web/locations/$LOCATION/managedApis/office365"
AZUREBLOB_API_ID="/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Web/locations/$LOCATION/managedApis/azureblob"
COSMOSDB_API_ID="/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Web/locations/$LOCATION/managedApis/documentdb"

# ── Read the workflow definition ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_TEMPLATE="$SCRIPT_DIR/../logic-app/workflow.json"

if [ ! -f "$WORKFLOW_TEMPLATE" ]; then
  echo "ERROR: Workflow definition not found at $WORKFLOW_TEMPLATE"
  exit 1
fi

echo "▸ Reading workflow definition from logic-app/workflow.json..."
WORKFLOW_DEFINITION=$(cat "$WORKFLOW_TEMPLATE")

# Replace account name placeholders with actual values
WORKFLOW_DEFINITION=$(echo "$WORKFLOW_DEFINITION" | sed "s/__STORAGE_ACCOUNT__/$STORAGE_ACCOUNT/g; s/__COSMOS_ACCOUNT__/$COSMOS_ACCOUNT/g")

# Replace Content Understanding placeholders (if configured)
if [ -n "$CONTENT_UNDERSTANDING_ENDPOINT" ]; then
  WORKFLOW_DEFINITION=$(echo "$WORKFLOW_DEFINITION" | sed "s|__CONTENT_UNDERSTANDING_ENDPOINT__|$CONTENT_UNDERSTANDING_ENDPOINT|g; s/__CONTENT_UNDERSTANDING_ANALYZER_ID__/$CONTENT_UNDERSTANDING_ANALYZER_ID/g")
fi

# ── Build and deploy the Logic App payload ───────────────────────────────────
# Uses az rest PUT — same atomic deploy as deploy.sh (lines 178-226)
# Preserves SystemAssigned managed identity (PUT is idempotent, won't rotate MI)
echo "▸ Deploying workflow definition to Logic App..."

PAYLOAD_FILE="$SCRIPT_DIR/.redeploy-logic-app-payload.json"

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

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Workflow Redeploy Complete                                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Logic App:        $LOGIC_APP"
echo "  Resource Group:   $RESOURCE_GROUP"
echo "  Location:         $LOCATION"
echo "  Workflow Source:   logic-app/workflow.json"
echo "  Identity:         SystemAssigned (preserved)"
echo "  Connections:      office365, azureblob, cosmosdb (MI auth)"
echo ""
echo "  ✓ Workflow definition updated"
echo "  ✓ Managed identity preserved"
echo "  ✓ \$connections parameters refreshed"
echo ""
