#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Enable public network access on Storage Account and Cosmos DB
###############################################################################

RESOURCE_GROUP="${RESOURCE_GROUP:-email-analyzer-rg}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-emailanalyzerstor}"
COSMOS_ACCOUNT="${COSMOS_ACCOUNT:-email-analyzer-cosmos}"

echo "▸ Enabling public network access on Storage Account ($STORAGE_ACCOUNT)..."
az storage account update \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --default-action Allow \
  --output none

echo "▸ Enabling public network access on Cosmos DB ($COSMOS_ACCOUNT)..."
az cosmosdb update \
  --name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --enable-public-network true \
  --output none

echo ""
echo "✓ Public endpoints enabled:"
echo "  Storage Account: $STORAGE_ACCOUNT"
echo "  Cosmos DB:       $COSMOS_ACCOUNT"
