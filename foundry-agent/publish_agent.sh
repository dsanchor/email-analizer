#!/usr/bin/env bash
# publish_agent.sh — Publish an Azure AI Foundry agent as an Agent Application
#
# Creates the Agent Application, deploys it with the Responses protocol,
# verifies the deployment, and optionally grants Azure AI User role.
#
# Usage:
#   ./publish_agent.sh [--help] [--grant-role <principal_id>]
#
# Required env vars (or override via export before running):
#   SUBSCRIPTION_ID   — Azure subscription ID
#   RESOURCE_GROUP    — Resource group containing the Foundry account
#   ACCOUNT_NAME      — Cognitive Services / AI Foundry account name
#   PROJECT_NAME      — Foundry project name
#
# Optional env vars (with defaults):
#   APPLICATION_NAME  — Agent Application name      (default: email-classifier)
#   DEPLOYMENT_NAME   — Deployment name              (default: default)
#   AGENT_NAME        — Agent name inside Foundry    (default: EmailClassifierAgent)
#   AGENT_VERSION     — Agent version to deploy      (default: 1)
#   API_VERSION       — ARM API version              (default: 2026-03-15-preview)

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}ℹ ${NC}$*"; }
success() { echo -e "${GREEN}✅ ${NC}$*"; }
warn()    { echo -e "${YELLOW}⚠️  ${NC}$*"; }
error()   { echo -e "${RED}❌ ${NC}$*"; }
step()    { echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") [OPTIONS]

Publish an Azure AI Foundry agent as an Agent Application with a managed
deployment using the Responses protocol.

${BOLD}Options:${NC}
  --help                  Show this help message
  --grant-role <ID>       Grant Azure AI User role to the given principal ID

${BOLD}Required environment variables:${NC}
  SUBSCRIPTION_ID         Azure subscription ID
  RESOURCE_GROUP          Resource group name
  ACCOUNT_NAME            Cognitive Services / AI Foundry account name
  PROJECT_NAME            Foundry project name

${BOLD}Optional environment variables (defaults shown):${NC}
  APPLICATION_NAME        Agent Application name       [email-classifier]
  DEPLOYMENT_NAME         Deployment name              [default]
  AGENT_NAME              Agent name in Foundry        [EmailClassifierAgent]
  AGENT_VERSION           Agent version                [1]
  API_VERSION             ARM API version              [2026-03-15-preview]

${BOLD}Examples:${NC}
  # Minimal — set required vars and run
  export SUBSCRIPTION_ID=aaaa-bbbb RESOURCE_GROUP=my-rg \\
         ACCOUNT_NAME=my-ai PROJECT_NAME=my-project
  ./publish_agent.sh

  # With role grant
  ./publish_agent.sh --grant-role 00000000-0000-0000-0000-000000000000
EOF
    exit 0
}

# ─── Parse args ──────────────────────────────────────────────────────────────
GRANT_PRINCIPAL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage ;;
        --grant-role)
            shift
            GRANT_PRINCIPAL="${1:?--grant-role requires a principal ID}"
            shift
            ;;
        *)
            error "Unknown option: $1"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

# ─── Config ──────────────────────────────────────────────────────────────────
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
RESOURCE_GROUP="${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
ACCOUNT_NAME="${ACCOUNT_NAME:?Set ACCOUNT_NAME}"
PROJECT_NAME="${PROJECT_NAME:?Set PROJECT_NAME}"

APPLICATION_NAME="${APPLICATION_NAME:-email-classifier}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-default}"
AGENT_NAME="${AGENT_NAME:-EmailClassifierAgent}"
AGENT_VERSION="${AGENT_VERSION:-1}"
API_VERSION="${API_VERSION:-2026-03-15-preview}"

BASE_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${ACCOUNT_NAME}/projects/${PROJECT_NAME}"

info "Configuration:"
echo "  Subscription:   ${SUBSCRIPTION_ID}"
echo "  Resource Group:  ${RESOURCE_GROUP}"
echo "  Account:         ${ACCOUNT_NAME}"
echo "  Project:         ${PROJECT_NAME}"
echo "  Application:     ${APPLICATION_NAME}"
echo "  Deployment:      ${DEPLOYMENT_NAME}"
echo "  Agent:           ${AGENT_NAME} v${AGENT_VERSION}"
echo "  API Version:     ${API_VERSION}"

# ─── Authenticate ────────────────────────────────────────────────────────────
step "Authenticating"

# Ensure we're logged in
if ! az account show &>/dev/null; then
    info "Not logged in — running az login..."
    az login --only-show-errors
fi

info "Fetching ARM access token..."
TOKEN=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
if [[ -z "${TOKEN}" ]]; then
    error "Failed to obtain access token"
    exit 1
fi
success "Token acquired"

# ─── Helper: call ARM and check status ───────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_FILE="${SCRIPT_DIR}/.publish-agent-payload.json"

arm_call() {
    local method="$1" url="$2" description="$3"
    # $4 is optional body file
    local body_args=()
    if [[ -n "${4:-}" ]]; then
        body_args=(--data-binary "@${4}")
    fi

    local http_code body_file="${SCRIPT_DIR}/.publish-agent-response.json"

    http_code=$(curl -s -o "${body_file}" -w "%{http_code}" \
        -X "${method}" \
        "${url}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        "${body_args[@]}")

    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
        success "${description} (HTTP ${http_code})"
        cat "${body_file}"
        rm -f "${body_file}"
        return 0
    else
        error "${description} failed (HTTP ${http_code})"
        echo -e "${RED}Response:${NC}"
        cat "${body_file}" 2>/dev/null || true
        echo
        rm -f "${body_file}"
        return 1
    fi
}

# ─── Step 1: Create Agent Application ────────────────────────────────────────
step "Step 1 — Create Agent Application"

APP_URL="${BASE_URL}/applications/${APPLICATION_NAME}?api-version=${API_VERSION}"

cat > "${PAYLOAD_FILE}" <<EOF
{
  "properties": {
    "agents": [
      {
        "agentName": "${AGENT_NAME}"
      }
    ]
  }
}
EOF

info "PUT ${APPLICATION_NAME}..."
arm_call PUT "${APP_URL}" "Agent Application created" "${PAYLOAD_FILE}"
echo

# ─── Step 2: Create Managed Deployment ───────────────────────────────────────
step "Step 2 — Create Managed Deployment (Responses protocol)"

DEPLOY_URL="${BASE_URL}/applications/${APPLICATION_NAME}/agentdeployments/${DEPLOYMENT_NAME}?api-version=${API_VERSION}"

cat > "${PAYLOAD_FILE}" <<EOF
{
  "properties": {
    "displayName": "Email Classifier Deployment",
    "deploymentType": "Managed",
    "protocols": [
      {
        "protocol": "Responses",
        "version": "1.0"
      }
    ],
    "agents": [
      {
        "agentName": "${AGENT_NAME}",
        "agentVersion": "${AGENT_VERSION}"
      }
    ]
  }
}
EOF

info "PUT ${DEPLOYMENT_NAME}..."
arm_call PUT "${DEPLOY_URL}" "Managed deployment created" "${PAYLOAD_FILE}"
echo

# ─── Step 3: Verify Deployment ───────────────────────────────────────────────
step "Step 3 — Verify Deployment"

info "Checking deployment state..."
MAX_ATTEMPTS=12
WAIT_SECONDS=10

for (( i=1; i<=MAX_ATTEMPTS; i++ )); do
    VERIFY_RESPONSE=$(curl -s \
        -X GET "${DEPLOY_URL}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json")

    PROVISIONING_STATE=$(echo "${VERIFY_RESPONSE}" | grep -o '"provisioningState":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ "${PROVISIONING_STATE}" == "Succeeded" ]]; then
        success "Deployment is running (provisioningState: Succeeded)"
        break
    elif [[ "${PROVISIONING_STATE}" == "Failed" ]]; then
        error "Deployment failed!"
        echo "${VERIFY_RESPONSE}"
        rm -f "${PAYLOAD_FILE}"
        exit 1
    else
        info "Attempt ${i}/${MAX_ATTEMPTS} — state: ${PROVISIONING_STATE:-unknown}. Waiting ${WAIT_SECONDS}s..."
        sleep "${WAIT_SECONDS}"
    fi
done

if [[ "${PROVISIONING_STATE}" != "Succeeded" ]]; then
    warn "Deployment did not reach 'Succeeded' state after $((MAX_ATTEMPTS * WAIT_SECONDS))s"
    warn "Current state: ${PROVISIONING_STATE:-unknown}"
    warn "The deployment may still be provisioning. Check the Azure portal."
fi

# ─── Step 4 (optional): Grant Azure AI User role ─────────────────────────────
if [[ -n "${GRANT_PRINCIPAL}" ]]; then
    step "Step 4 — Grant Azure AI User role"

    APP_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${ACCOUNT_NAME}/projects/${PROJECT_NAME}/applications/${APPLICATION_NAME}"
    # Azure AI User built-in role
    ROLE_DEFINITION_ID="73a6e015-9529-4d9c-a5de-0c9e9f4cac6e"

    info "Assigning Azure AI User role to principal ${GRANT_PRINCIPAL}..."
    az role assignment create \
        --assignee-object-id "${GRANT_PRINCIPAL}" \
        --role "${ROLE_DEFINITION_ID}" \
        --scope "${APP_RESOURCE_ID}" \
        --assignee-principal-type ServicePrincipal \
        --only-show-errors \
    && success "Role assigned" \
    || warn "Role assignment failed — you may need to assign it manually"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
step "Done"

INVOKE_URL="https://${ACCOUNT_NAME}.services.ai.azure.com/api/projects/${PROJECT_NAME}/applications/${APPLICATION_NAME}/protocols/openai/responses?api-version=2025-11-15-preview"

echo
success "Agent Application published!"
echo
info "Invocation endpoint (Responses protocol):"
echo -e "  ${BOLD}${INVOKE_URL}${NC}"
echo
info "Quick test (requires token with audience https://ai.azure.com):"
echo -e "  ${CYAN}curl -X POST '${INVOKE_URL}' \\\\${NC}"
echo -e "  ${CYAN}  -H 'Authorization: Bearer <token>' \\\\${NC}"
echo -e "  ${CYAN}  -H 'Content-Type: application/json' \\\\${NC}"
echo -e "  ${CYAN}  -d '{\"input\": \"Say hello\"}'${NC}"
echo

# ─── Cleanup ─────────────────────────────────────────────────────────────────
rm -f "${PAYLOAD_FILE}"
