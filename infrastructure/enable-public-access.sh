#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Enable public network access on Storage Account and Cosmos DB
###############################################################################

RESOURCE_GROUP="${RESOURCE_GROUP:-email-analyzer-rg}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-emailanalyzerstor}"
STORAGE_ACCOUNT_FUNCTION="${STORAGE_ACCOUNT_FUNCTION:-emailanalyzerfuncstor}"
COSMOS_ACCOUNT="${COSMOS_ACCOUNT:-email-analyzer-cosmos}"

echo "▸ Enabling public network access on Storage Account ($STORAGE_ACCOUNT)..."
az storage account update \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --default-action Allow \
  --public-network-access Enabled \
  --output none

echo "▸ Enabling public network access on Storage Account ($STORAGE_ACCOUNT_FUNCTION)..."
az storage account update \
  --name "$STORAGE_ACCOUNT_FUNCTION" \
  --resource-group "$RESOURCE_GROUP" \
  --default-action Allow \
  --public-network-access Enabled \
  --output none

echo "▸ Enabling public network access on Cosmos DB ($COSMOS_ACCOUNT)..."
az cosmosdb update \
  --name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --public-network-access ENABLED\
  --output none

echo ""
echo "✓ Public endpoints enabled:"
echo "  Storage Account: $STORAGE_ACCOUNT"
echo "  Storage Account: $STORAGE_ACCOUNT_FUNCTION"
echo "  Cosmos DB:       $COSMOS_ACCOUNT"


 # Restart to clear the unhealthy state
 az functionapp restart \
   --name email-analyzer-func \
   --resource-group "$RESOURCE_GROUP" 
