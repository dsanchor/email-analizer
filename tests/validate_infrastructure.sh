#!/usr/bin/env bash
# =============================================================================
# Infrastructure Validation Script for email-analyzer
#
# Validates that all required Azure resources exist and are correctly
# configured, including managed identity role assignments.
#
# Usage:
#   ./tests/validate_infrastructure.sh <resource-group> [subscription-id]
#
# Prerequisites: Azure CLI (az) authenticated with appropriate permissions
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables if needed
# ---------------------------------------------------------------------------
RESOURCE_GROUP="${1:?Usage: $0 <resource-group> [subscription-id]}"
SUBSCRIPTION="${2:-$(az account show --query id -o tsv 2>/dev/null)}"

COSMOS_ACCOUNT="${COSMOS_ACCOUNT:-email-analyzer-cosmos}"
COSMOS_DATABASE="${COSMOS_DATABASE:-email-analyzer-db}"
COSMOS_CONTAINER="${COSMOS_CONTAINER:-emails}"

STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-emailanalyzerstor}"
BLOB_CONTAINER="${BLOB_CONTAINER:-email-attachments}"

LOGIC_APP="${LOGIC_APP:-email-analyzer-logic}"
CONTAINER_APP="${CONTAINER_APP:-email-analyzer-app}"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "✅ PASS: ${description}"
        ((PASS++))
    else
        echo "❌ FAIL: ${description}"
        ((FAIL++))
    fi
}

header() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
header "Pre-flight checks"
check "Azure CLI is installed" command -v az
check "Logged in to Azure" az account show
echo "  Subscription: ${SUBSCRIPTION}"
echo "  Resource Group: ${RESOURCE_GROUP}"

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
header "Resource Group"
check "Resource group '${RESOURCE_GROUP}' exists" \
    az group show --name "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION}"

# ---------------------------------------------------------------------------
# Cosmos DB
# ---------------------------------------------------------------------------
header "Cosmos DB"
check "Cosmos DB account '${COSMOS_ACCOUNT}' exists" \
    az cosmosdb show --name "${COSMOS_ACCOUNT}" -g "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION}"

check "Cosmos DB database '${COSMOS_DATABASE}' exists" \
    az cosmosdb sql database show --account-name "${COSMOS_ACCOUNT}" --name "${COSMOS_DATABASE}" \
        -g "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION}"

check "Cosmos DB container '${COSMOS_CONTAINER}' exists" \
    az cosmosdb sql container show --account-name "${COSMOS_ACCOUNT}" --database-name "${COSMOS_DATABASE}" \
        --name "${COSMOS_CONTAINER}" -g "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION}"

# ---------------------------------------------------------------------------
# Storage Account
# ---------------------------------------------------------------------------
header "Storage Account"
check "Storage account '${STORAGE_ACCOUNT}' exists" \
    az storage account show --name "${STORAGE_ACCOUNT}" -g "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION}"

check "Blob container '${BLOB_CONTAINER}' exists" \
    az storage container show --name "${BLOB_CONTAINER}" --account-name "${STORAGE_ACCOUNT}" \
        --auth-mode login --subscription "${SUBSCRIPTION}"

# ---------------------------------------------------------------------------
# Logic App
# ---------------------------------------------------------------------------
header "Logic App"
check "Logic App '${LOGIC_APP}' exists" \
    az logic workflow show --name "${LOGIC_APP}" -g "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION}"

LOGIC_APP_MI=$(az logic workflow show --name "${LOGIC_APP}" -g "${RESOURCE_GROUP}" \
    --subscription "${SUBSCRIPTION}" --query "identity.type" -o tsv 2>/dev/null || echo "none")
check "Logic App has system-assigned managed identity" \
    test "${LOGIC_APP_MI}" = "SystemAssigned" -o "${LOGIC_APP_MI}" = "SystemAssigned, UserAssigned"

# ---------------------------------------------------------------------------
# Container App
# ---------------------------------------------------------------------------
header "Container App"
check "Container App '${CONTAINER_APP}' exists" \
    az containerapp show --name "${CONTAINER_APP}" -g "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION}"

CONTAINER_APP_MI=$(az containerapp show --name "${CONTAINER_APP}" -g "${RESOURCE_GROUP}" \
    --subscription "${SUBSCRIPTION}" --query "identity.type" -o tsv 2>/dev/null || echo "none")
check "Container App has system-assigned managed identity" \
    test "${CONTAINER_APP_MI}" = "SystemAssigned" -o "${CONTAINER_APP_MI}" = "SystemAssigned, UserAssigned"

# ---------------------------------------------------------------------------
# Role Assignments
# ---------------------------------------------------------------------------
header "Role Assignments"

# Get principal IDs
LOGIC_APP_PRINCIPAL=$(az logic workflow show --name "${LOGIC_APP}" -g "${RESOURCE_GROUP}" \
    --subscription "${SUBSCRIPTION}" --query "identity.principalId" -o tsv 2>/dev/null || echo "")
CONTAINER_APP_PRINCIPAL=$(az containerapp show --name "${CONTAINER_APP}" -g "${RESOURCE_GROUP}" \
    --subscription "${SUBSCRIPTION}" --query "identity.principalId" -o tsv 2>/dev/null || echo "")

check_role() {
    local principal_id="$1"
    local role_name="$2"
    local scope="$3"
    local description="$4"

    if [ -z "${principal_id}" ]; then
        echo "❌ FAIL: ${description} (principal ID not found)"
        ((FAIL++))
        return
    fi

    check "${description}" \
        az role assignment list --assignee "${principal_id}" --role "${role_name}" \
            --scope "${scope}" --subscription "${SUBSCRIPTION}" --query "[0].id" -o tsv
}

# Cosmos DB scope
COSMOS_ID=$(az cosmosdb show --name "${COSMOS_ACCOUNT}" -g "${RESOURCE_GROUP}" \
    --subscription "${SUBSCRIPTION}" --query "id" -o tsv 2>/dev/null || echo "")

# Storage scope
STORAGE_ID=$(az storage account show --name "${STORAGE_ACCOUNT}" -g "${RESOURCE_GROUP}" \
    --subscription "${SUBSCRIPTION}" --query "id" -o tsv 2>/dev/null || echo "")

if [ -n "${COSMOS_ID}" ]; then
    check_role "${CONTAINER_APP_PRINCIPAL}" "Cosmos DB Built-in Data Reader" "${COSMOS_ID}" \
        "Container App → Cosmos DB Built-in Data Reader"

    check_role "${LOGIC_APP_PRINCIPAL}" "Cosmos DB Built-in Data Contributor" "${COSMOS_ID}" \
        "Logic App → Cosmos DB Built-in Data Contributor"
fi

if [ -n "${STORAGE_ID}" ]; then
    check_role "${CONTAINER_APP_PRINCIPAL}" "Storage Blob Data Reader" "${STORAGE_ID}" \
        "Container App → Storage Blob Data Reader"

    check_role "${LOGIC_APP_PRINCIPAL}" "Storage Blob Data Contributor" "${STORAGE_ID}" \
        "Logic App → Storage Blob Data Contributor"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Summary"
TOTAL=$((PASS + FAIL))
echo "  Total checks: ${TOTAL}"
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo ""

if [ "${FAIL}" -gt 0 ]; then
    echo "⚠️  Some checks failed. Review the output above."
    exit 1
else
    echo "🎉 All checks passed!"
    exit 0
fi
