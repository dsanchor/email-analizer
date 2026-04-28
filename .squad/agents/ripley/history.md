## Learnings

- **Project:** email-analyzer — Azure Logic App email processing pipeline
- **Stack:** Python, Azure (Logic Apps, Cosmos DB, Blob Storage, Container Apps), managed identities
- **User:** dsanchor
- **Reference:** https://github.com/glory-ub/PDF-Extraction-from-Mail-using-Logic-App

### Session: Logic App Workflow & Deploy Script
- Created `logic-app/workflow.json` — Stateful Logic App Standard workflow
  - Uses splitOn on trigger (required by Office 365 V3 connector for per-message processing)
  - Processes ALL attachment types (no PDF filter)
  - Sequential attachment processing (concurrency: 1) to avoid variable race conditions
  - Stores blobs at `/email-attachments/{emailId}/{filename}`
  - Upserts to Cosmos DB with `x-ms-documentdb-is-upsert: True` header
- Created `logic-app/connections.json` — API connections config
  - Office 365: OAuth (requires interactive consent post-deploy)
  - Blob Storage: ManagedServiceIdentity auth
  - Cosmos DB: ManagedServiceIdentity auth (uses `documentdb` managed API)
- Created `infrastructure/deploy.sh` — Full AZ CLI deployment script
  - Cosmos DB: serverless, NoSQL API, partition key `/messageId`
  - Logic App Standard on WS1 App Service Plan
  - Container Apps with quickstart placeholder image
  - API connections provisioned via `az resource create`
  - Access policies grant Logic App MI access to API connections
- **Cosmos DB Built-in Role IDs:**
  - Data Reader: `00000000-0000-0000-0000-000000000001`
  - Data Contributor: `00000000-0000-0000-0000-000000000002`
- **Key files:** `logic-app/workflow.json`, `logic-app/connections.json`, `infrastructure/deploy.sh`

### Session: ACR to GitHub Packages Migration
- Replaced Azure Container Registry with GitHub Packages (ghcr.io) for container image hosting
- Removed ACR provisioning from `infrastructure/deploy.sh`:
  - Removed ACR_NAME config variable
  - Removed `az acr create` command section
  - Removed ACR_LOGIN_SERVER variable lookup
  - Removed `--registry-server` flag from Container App create
  - Removed AcrPull role assignment for Container App managed identity
- Created `.github/workflows/build-push.yml` — automated Docker build pipeline
  - Triggers on push to `main` when `web-app/` changes
  - Also supports manual trigger via `workflow_dispatch`
  - Builds from `web-app/Dockerfile`
  - Pushes to `ghcr.io/${{ github.repository }}/email-analyzer-web`
  - Tags with both `latest` and `<branch>-<sha>`
  - Uses built-in `GITHUB_TOKEN` (no secrets needed)
  - Requires `packages: write` and `contents: read` permissions
- Updated documentation:
  - `README.md`: Changed Quick Start step 4 to reference GH Actions workflow
  - `docs/architecture.md`: Updated "Container Registry" references to "GitHub Packages (ghcr.io)"
  - Updated Security Model section (removed ACR pull reference)
  - Updated Deployment Architecture section with workflow details
- **Rationale:** GitHub Packages is free for public repos, integrated with GH Actions, and eliminates one Azure resource to provision/maintain
- **Key files affected:** `infrastructure/deploy.sh`, `.github/workflows/build-push.yml`, `README.md`, `docs/architecture.md`

### Session: Logic App Standard → Consumption Migration
- **Trigger:** Logic App Standard deployment failed because it requires storage account shared keys, and the user's policy mandates `--allow-shared-key-access false`
- Rewrote `infrastructure/deploy.sh`:
  - Removed App Service Plan (WS1) — Consumption doesn't need it
  - Removed `APP_SERVICE_PLAN` config variable
  - Removed `az logicapp create` / `az webapp identity assign` / `az webapp identity show` (Standard-specific commands)
  - Added `az resource create --resource-type Microsoft.Logic/workflows` for Consumption Logic App
  - Deploy script reads `logic-app/workflow.json` and injects it as the definition in the ARM resource body
  - `$connections` parameters (office365, azureblob, cosmosdb) are populated with actual subscription/RG/connection IDs at deploy time
  - System-assigned managed identity enabled via `az resource update --set identity`
  - Changed `--allow-shared-key-access true` → `--allow-shared-key-access false` on storage account
  - Moved API connection creation BEFORE Logic App creation (connections must exist for the workflow definition)
  - Removed `az logicapp show` from summary; Logic App Consumption has no public URL
- Rewrote `logic-app/workflow.json`:
  - Removed `"kind": "Stateful"` wrapper (Consumption doesn't use kind)
  - Changed from Standard format (wrapped in `definition` + `kind`) to bare workflow definition
  - Changed connection references from `"referenceName"` to `"name": "@parameters('$connections')['<name>']['connectionId']"` (Consumption format)
- Rewrote `logic-app/connections.json`:
  - Replaced Standard `managedApiConnections` with `@appsetting()` references → reference-only doc
  - File is now documentation only; Consumption Logic Apps don't use connections.json at runtime
- Updated `README.md`: removed Logic App Standard references, removed separate workflow deploy step
- Updated `docs/architecture.md`: changed all Standard/WS1/ASP references to Consumption
- **Key pattern:** Consumption Logic Apps get their workflow definition + connections embedded in the ARM resource at deploy time, unlike Standard which uses separate deployment
- **User policy:** Zero shared keys anywhere — storage account `--allow-shared-key-access false`
- **Key files:** `infrastructure/deploy.sh`, `logic-app/workflow.json`, `logic-app/connections.json`, `README.md`, `docs/architecture.md`

### Session: Logic App Recursive Input Nesting Fix
- **Issue:** Run history showed infinite recursive `Inputs > value > Inputs > value...` nesting pattern
- **Root cause:** Office 365 V3 connector's `body` field is an object `{ content: "...", contentType: "..." }`, not a string
  - When referenced multiple times in workflow (Compose action + Cosmos action), Logic Apps run history tracking creates nested representations
  - The `Compose_Email_Metadata` action was unused — it composed trigger body but was never referenced downstream
- **Fix applied to `logic-app/workflow.json`:**
  - Removed unused `Compose_Email_Metadata` action (reduced redundant trigger references)
  - Changed Cosmos document body field from `@{triggerBody()?['body']}` → `@{triggerBody()?['body']?['content']}`
  - Now extracts only the HTML/text string content instead of storing the entire object
- **Impact:**
  - Run history is now clean and readable
  - Cosmos DB `body` field correctly stores HTML string (as originally intended)
  - No web app changes needed — Lambert's templates already expected `body` to be a string
  - Performance improvement from removing unused action step
- **Prevention pattern:** Always access `triggerBody()?['body']?['content']` explicitly when using Office 365 V3 connector
- **Key file:** `logic-app/workflow.json`
- **Decision doc:** `.squad/decisions/inbox/ripley-logic-app-recursive-fix.md`

### Session: Cosmos DB BadGateway Fix
- **Issue:** `Create_or_Update_Cosmos_Document` action failing with 502 BadGateway
- **Root causes identified:**
  1. `from` field used string interpolation `@{triggerBody()?['from']}` on a complex object `{emailAddress: {name, address}}` — serializes to garbage, corrupts the Cosmos document body
  2. `messageId` (partition key `/messageId`) used `@{triggerBody()?['internetMessageId']}` with no null fallback — empty partition key value causes BadGateway
- **Fix applied to `logic-app/workflow.json`:**
  - Changed `from` from `@{triggerBody()?['from']}` → `@triggerBody()?['from']` (no string interpolation — preserves JSON object)
  - Changed `messageId` from `@{triggerBody()?['internetMessageId']}` → `@{coalesce(triggerBody()?['internetMessageId'], triggerBody()?['id'])}` (fallback to O365 ID if internetMessageId is null)
- **Pattern:** In Logic App expressions, use `@expr` (no braces) for objects/arrays, use `@{expr}` only for string values. Mixing these up is a common BadGateway source.
- **Key insight:** `toRecipients`, `hasAttachments`, and `attachments` were already correct (no string interpolation on non-string types)
- **Key file:** `logic-app/workflow.json`
- **Decision doc:** `.squad/decisions/inbox/ripley-cosmos-badgateway-fix.md`

### Session: Logic App Workflow Redeploy Script
- Created `infrastructure/redeploy-logic-app.sh` — focused script that ONLY redeploys the Logic App workflow definition
  - Validates Logic App exists before attempting deploy (fail-fast with helpful error)
  - Uses same config variables and naming conventions as `deploy.sh` (RESOURCE_GROUP, LOCATION, LOGIC_APP)
  - Reads `logic-app/workflow.json` and deploys via `az rest --method PUT` (same ARM pattern as deploy.sh)
  - Builds `$connections` parameters from subscription/RG IDs (office365, azureblob with MI, cosmosdb with MI)
  - Preserves SystemAssigned managed identity (PUT is idempotent, won't rotate principal)
  - Writes temp payload to `infrastructure/.redeploy-logic-app-payload.json` (not /tmp) and cleans up after
  - Does NOT create any resources — no RG, Cosmos, Storage, Container App, or API connections
- **Use case:** Quick workflow iteration — edit workflow.json, run redeploy, test in portal
- **Key file:** `infrastructure/redeploy-logic-app.sh`

### Session: Azure Blob Storage API Connection InternalServerError Fix
- **Issue:** `az resource create` for the azureblob API connection returned InternalServerError every time
- **Root causes:**
  1. `accountName` is not a valid parameter for the `managedIdentityAuth` parameter value set — the correct key would be `storageAccount`, but MI auth needs no values at all
  2. `az resource create` doesn't give explicit control over the ARM API version (`2016-06-01` required for `Microsoft.Web/connections`)
- **Fix applied to `infrastructure/deploy.sh`:**
  - Replaced `az resource create` with `az rest --method PUT` using explicit API version `2016-06-01`
  - Changed `parameterValueSet.values` from `{ "accountName": { "value": "..." } }` to empty `{}`
  - MI auth for blob is already handled at Logic App `$connections` level via `connectionProperties.authentication.type: ManagedServiceIdentity`
  - Moved temp payload file from `/tmp/` to `$SCRIPT_DIR/.deploy-logic-app-payload.json` (consistent with redeploy script pattern)
- **Pattern:** For `managedIdentityAuth` connections, the `parameterValueSet.values` should be empty — storage account targeting is handled by the workflow actions, not the connection resource
- **`redeploy-logic-app.sh`:** No changes needed — it doesn't create API connections
- **Key files:** `infrastructure/deploy.sh`, `.gitignore`

### Session: API Connection Endpoint Resolution — AccountNameFromSettings Fix
- **Issue:** Blob (Unauthorized) and Cosmos DB (502 BadGateway/timeout) actions failed because the managed API connectors couldn't resolve which account to target
- **Root cause:** `workflow.json` used the literal placeholder `AccountNameFromSettings` in the action paths for both blob and Cosmos connectors. The connector uses the account name in the path (not the connection resource properties) to determine which account to authenticate against.
- **Fix applied:**
  1. `logic-app/workflow.json` — replaced `AccountNameFromSettings` with deploy-time placeholders:
     - Blob path: `__STORAGE_ACCOUNT__`
     - Cosmos path: `__COSMOS_ACCOUNT__`
  2. `infrastructure/deploy.sh` — added sed substitution after reading workflow template to replace `__STORAGE_ACCOUNT__` → `$STORAGE_ACCOUNT` and `__COSMOS_ACCOUNT__` → `$COSMOS_ACCOUNT`
  3. `infrastructure/redeploy-logic-app.sh` — added same sed substitution + added `COSMOS_ACCOUNT` and `STORAGE_ACCOUNT` config variables (previously missing)
- **Pattern:** Managed API connectors (blob, cosmosdb) resolve target accounts from the ACTION PATH, not from the connection resource parameters. The connection resource just needs `api` + `displayName`; MI auth is declared in the `$connections` block. The actual account routing comes from the path: `/v2/cosmosdb/{accountName}/dbs/...` and `/v2/datasets/{storageAccount}/files`.
- **Key insight:** `parameterValueSet` with `managedIdentityAuth` caused InternalServerError for blob; keeping connection resources minimal (api + displayName only) and relying on correct action paths is the safest pattern.
- **Key files:** `logic-app/workflow.json`, `infrastructure/deploy.sh`, `infrastructure/redeploy-logic-app.sh`
- **Decision doc:** `.squad/decisions/inbox/ripley-connection-endpoints.md`

---

### Cross-Team Update from Lambert (2026-04-20)

**✅ UI REFRESH: Data Model Compatibility Solution**
- **Change:** Lambert implemented Jinja2 template filters to handle polymorphic Cosmos DB field types
- **What happened:** Your Logic App fix changed `from` field type from string to JSON object. Templates needed updates to handle both old and new formats transparently.
- **Solution:** Added 5 template filters (`extract_from`, `extract_from_display`, `extract_from_initial`, `extract_body`, `extract_recipients`) that normalize field access across all templates
- **Your Action:** No code changes needed in Logic App. Web app now handles both data formats transparently.
- **Impact:** Frontend reliability — dashboard and detail pages render correctly with properly-typed Cosmos data
- **New Feature:** Dashboard route added (`GET /dashboard`) with email statistics
- **Test Status:** All 30 tests still passing (Lambert confirmed)

### Session: Subject Filter Parameterization
- **Change:** Made the email subject filter configurable via `SUBJECT_FILTER` env var with `__SUBJECT_FILTER__` placeholder
- **Files modified:**
  - `logic-app/workflow.json`: Replaced hardcoded `"Demo email"` with `__SUBJECT_FILTER__` in 3 places (fetch queries, subscribe queries, trigger condition)
  - `infrastructure/deploy.sh`: Added `SUBJECT_FILTER` config var (default: `Demo email`), echo in config output, sed replacement on line 176
  - `infrastructure/redeploy-logic-app.sh`: Same additions — config var, echo, sed replacement
- **Pattern:** Follows existing `__STORAGE_ACCOUNT__` / `__COSMOS_ACCOUNT__` placeholder convention — plain string sed substitution at deploy time
- **Usage:** Override at deploy time with `SUBJECT_FILTER="My custom prefix" ./infrastructure/deploy.sh`
- **Key files:** `logic-app/workflow.json`, `infrastructure/deploy.sh`, `infrastructure/redeploy-logic-app.sh`

### Session: Azure Content Understanding Integration
- **Context:** Integrate Azure Content Understanding API to extract fields from PDF email attachments
- **Changes made:**
  1. **`logic-app/workflow.json`:** Added PDF detection and Content Understanding API call
     - Replaced `Append_Attachment_Info` with conditional `Check_If_PDF` action
     - For PDFs: calls Content Understanding API via HTTP action with managed identity auth
     - HTTP action uses async pattern (automatic polling via Operation-Location header)
     - Sends PDF content as base64 in request body (avoids blob storage access complexity)
     - Stores analysis result in `contentUnderstanding` field of attachment object
     - For non-PDFs: appends attachment info without analysis (original behavior)
     - Uses placeholders `__CONTENT_UNDERSTANDING_ENDPOINT__` and `__CONTENT_UNDERSTANDING_ANALYZER_ID__`
  2. **`infrastructure/deploy.sh`:** Added Content Understanding configuration
     - New config variables: `CONTENT_UNDERSTANDING_ENDPOINT`, `CONTENT_UNDERSTANDING_ANALYZER_ID`, `CONTENT_UNDERSTANDING_RESOURCE_ID`
     - Added sed substitution for placeholders (same pattern as storage/cosmos account names)
     - Added role assignment: Logic App MI → `Cognitive Services User` on Content Understanding resource (if configured)
     - Updated summary output to show Content Understanding configuration
  3. **`infrastructure/redeploy-logic-app.sh`:** Same sed substitution and config variables
  4. **`README.md`:** Documented Content Understanding integration
     - Added section explaining the optional integration
     - Documented setup steps (endpoint, analyzer ID, resource ID env vars)
     - Updated security table with new role assignment
     - Clarified that Content Understanding is an external service — users provision and configure it separately
- **Architecture pattern:**
  - Content Understanding is **optional** — if env vars not set, placeholders remain and PDFs are still processed (just without analysis)
  - Uses managed identity auth with audience `https://cognitiveservices.azure.com/`
  - Sends PDF content directly as base64 (avoids need for Content Understanding to access blob storage)
  - Analysis result stored alongside attachment metadata in Cosmos DB
  - HTTP action's built-in async polling handles the Operation-Location pattern automatically
- **CosmosDB schema change:**
  - PDF attachments now have `contentUnderstanding` field with analysis JSON
  - Non-PDF attachments omit the field (cleaner than storing nulls)
- **Key files:** `logic-app/workflow.json`, `infrastructure/deploy.sh`, `infrastructure/redeploy-logic-app.sh`, `README.md`
- **Decision doc:** `.squad/decisions/inbox/ripley-content-understanding.md`

### Session: Foundry Agent Email Classification
- Added `Classify_Email` HTTP action to `logic-app/workflow.json`
  - Calls Azure AI Foundry Response API via managed identity (audience: cognitiveservices)
  - Uses `__FOUNDRY_AGENT_ENDPOINT__` and `__FOUNDRY_AGENT_MODEL__` placeholders
  - Runs after `For_Each_Attachment` succeeds
- Added `Parse_Classification` Compose action to extract JSON from agent response
  - Parses `body('Classify_Email')?['output']` as JSON
- Updated `Create_or_Update_Cosmos_Document`:
  - `runAfter` now depends on both `For_Each_Attachment` (Succeeded, Failed) and `Parse_Classification` (Succeeded, Failed, Skipped)
  - New `classification` field added to Cosmos document body
- **Resilience pattern:** Classification failure doesn't block Cosmos write (runAfter includes Failed/Skipped)
- Updated `infrastructure/deploy.sh` and `infrastructure/redeploy-logic-app.sh`:
  - New env vars: `FOUNDRY_AGENT_ENDPOINT`, `FOUNDRY_AGENT_MODEL`
  - sed replacement for placeholders (same pipe pattern as Content Understanding)
  - Summary output shows Foundry config when set
- **Key files:** `logic-app/workflow.json`, `infrastructure/deploy.sh`, `infrastructure/redeploy-logic-app.sh`

### Session: Foundry Agent Provisioning Script
- Created `foundry-agent/create_classifier_agent.py` — Python script to provision EmailClassifierAgent in Azure AI Foundry
  - Uses `azure-ai-projects` async SDK with `DefaultAzureCredential`
  - Comprehensive classification instructions covering 13 categories (policy_management, billing_inquiry, claim_submission, claim_status, technical_support, complaint, information_request, account_management, compliance, sales_inquiry, feedback, spam, unknown)
  - Agent returns strict JSON: `{"type": "...", "score": 0-100, "reasoning": "..."}`
  - Includes worked examples in the prompt for few-shot guidance
- Created `foundry-agent/requirements.txt` with `azure-ai-projects` and `azure-identity`
- Updated `README.md`:
  - Added numbered Prerequisites subsections for Foundry Agent and Content Understanding
  - Documented env vars (`AZURE_AI_PROJECT_ENDPOINT`, `AZURE_AI_MODEL_DEPLOYMENT_NAME`) and setup steps
  - Linked deploy-time variables (`FOUNDRY_AGENT_ENDPOINT`, `FOUNDRY_AGENT_MODEL`) to Logic App deployment
  - Added `foundry-agent/` to Project Structure tree
- **Key files:** `foundry-agent/create_classifier_agent.py`, `foundry-agent/requirements.txt`, `README.md`
- **Decision doc:** `.squad/decisions/inbox/ripley-foundry-agent.md`

### Cross-Agent Context — Session 2026-04-25

**From Lambert:** Classification UI now live in EmailList (Type/Score sortable columns) and EmailDetail (full classification section with type pill, score bar, reasoning). Design maintains Apple Blue only — no new accent colors.

**Testing implications:** Kane needs test coverage for:
- Sorting by Type and Score columns in EmailList
- Null classification handling (section hidden on EmailDetail)
- Badge rendering for type pills (blue for real classifications, gray for "unknown")

**Data flow confirmed:** Logic App → Cosmos DB classification field → Web App display

---

### Session: Fix Foundry Response API URL Pattern
- Updated `logic-app/workflow.json` — Classify_Email URI now uses the correct Foundry Response API path:
  `{endpoint}/api/projects/default/applications/{app-name}/protocols/openai/responses?api-version=2025-11-15-preview`
- Removed `model`/`instructions` from body (configured on the agent in Foundry); body is now `{"input": "..."}`
- Updated Parse_Classification to extract from Response API nested output format: `output[0].content[0].text`
- Renamed `FOUNDRY_AGENT_MODEL` → `FOUNDRY_AGENT_APP_NAME` across deploy scripts and README
- Added deployment variable hints to `create_classifier_agent.py` output
- **Key learning:** Foundry Response API uses application-name-based routing, not model-based. The endpoint is the base `.services.ai.azure.com` URL, and the app name goes in the path.

### Session: Fix Parse_Classification Output Index
- Fixed Foundry agent response parsing in `logic-app/workflow.json` Parse_Classification action
- **Problem:** Response contains two output blocks:
  - `output[0]` — reasoning block (no classification content)
  - `output[1]` — message block (actual classification JSON)
- **Fix:** Changed expression from `output[0]` to `output[1]` (line 257)
- **Result:** Classification data now flows correctly to Cosmos DB
- **Status:** SUCCESS — Logic App workflow completes; classification stored in email documents

### Session: Add `status` Field to Cosmos Document
- Added `"status": "classified"` to the Cosmos DB document body in `Create_or_Update_Cosmos_Document` action
- Placed after `processedAt` — represents the final processing state of the email
- Static string value (not an expression) — by the time the Logic App writes to Cosmos, classification has already run
- **Key file:** `logic-app/workflow.json` (line 288)

### Session: Foundry Agent Publish Script
- Created `foundry-agent/publish_agent.sh` — bash script to publish a Foundry agent as an Agent Application via ARM REST API
- **4-step workflow:**
  1. Create Agent Application (PUT) — links agent name to application resource
  2. Create Managed Deployment (PUT) — configures Responses protocol v1.0
  3. Verify Deployment — polls provisioningState up to 12 attempts (120s total)
  4. (Optional) Grant Azure AI User role to a principal for invocation access
- **Auth:** Uses `az account get-access-token --resource https://management.azure.com` for ARM calls
- **Invocation note:** Published agent is invoked via `https://{account}.services.ai.azure.com/...` with audience `https://ai.azure.com` (different from ARM token)
- **Defaults:** agent_name=EmailClassifierAgent, application_name=email-classifier, deployment_name=default, api_version=2025-05-15-preview
- **Features:** `set -euo pipefail`, color output, HTTP status checking, `--help` flag, `--grant-role <principal_id>` option
- **Cleanup:** Temp payload files written to script dir (not /tmp), cleaned up on completion
- **Key file:** `foundry-agent/publish_agent.sh`

### Session: StatusHistory Array — Replace Single Status Field
- **Change:** Replaced single `"status": "classified"` field with `statusHistory` array of `{status, timestamp}` objects
- **Implementation in `logic-app/workflow.json`:**
  - Added `Initialize_Status_History` variable (array) initialized with `[{"status": "Email received", "timestamp": "@{utcNow()}"}]`
  - Added `Create_Initial_Cosmos_Document` — first upsert with email content + statusHistory (no attachments/classification yet)
  - Added `Check_Has_Attachments` condition after For_Each_Attachment loop
    - True branch: appends "Attachments processed" to statusHistory, upserts with attachments array
    - False branch: no-op
  - Added `Append_Classified_Status` — appends "Email classified" to statusHistory after Parse_Classification
  - Renamed final action from `Create_or_Update_Cosmos_Document` → `Update_Cosmos_Final`
  - Final upsert includes classification, processedAt, and full statusHistory
- **Flow:** Trigger → Init vars → Initial Cosmos upsert → For_Each_Attachment → Check_Has_Attachments (conditional upsert) → Classify → Parse → Append status → Final upsert
- **Resilience:** `Update_Cosmos_Final` runAfter includes `Check_Has_Attachments: [Succeeded, Failed]` and `Append_Classified_Status: [Succeeded, Failed, Skipped]` so the document is always updated even if classification fails
- **Pattern:** Use Logic App array variable + AppendToArrayVariable to build statusHistory incrementally across multiple upserts
- **Key file:** `logic-app/workflow.json`
- **Decision doc:** `.squad/decisions/inbox/ripley-status-history.md`

---

### Session: Cosmos DB RBAC Fix — Container App Delete Permission
- **Problem:** Container App MI had `Cosmos DB Built-in Data Reader` (00000000-0000-0000-0000-000000000001) which blocks delete operations needed by `DELETE /api/emails/:id`
- **Fix:** Upgraded to `Cosmos DB Built-in Data Contributor` (00000000-0000-0000-0000-000000000002) — includes read, create, replace, AND delete
- **Files changed:** `infrastructure/deploy.sh`, `README.md`, `docs/architecture.md`, `.squad/decisions.md`
- **Pattern:** When a web app needs full CRUD on Cosmos DB, always use Data Contributor, not Data Reader
- **Note:** `redeploy-logic-app.sh` has no role assignments — safe, no changes needed

---

### Session: Azure Function — Cosmos DB Change Feed Processor
- **Task:** Create Python Azure Function triggered by Cosmos DB change feed to process classified emails
- **Created files:**
  - `azure-function/function_app.py` — Python v2 programming model function with `cosmos_db_trigger`
  - `azure-function/host.json` — Azure Functions host config (v2, extension bundle)
  - `azure-function/requirements.txt` — Python dependencies (azure-functions, azure-cosmos, azure-identity)
  - `azure-function/README.md` — Function documentation
  - `infrastructure/deploy-azure-function.sh` — Deployment script
- **Function behavior:**
  - Triggered on Cosmos DB change feed for `emails` container
  - Checks last `statusHistory` entry — processes only if status = "Email classified"
  - Appends new status: `{"status": "Processed by agent", "timestamp": "<UTC ISO>"}`
  - Adds `agentResult` field with mock validation data (title, statements array)
  - Uses Cosmos SDK with DefaultAzureCredential (managed identity) to write back updates
  - Idempotent: skips documents already marked "Processed by agent"
- **Deployment script (`deploy-azure-function.sh`):**
  - Creates dedicated storage account for Function App internal state (`$FUNCTION_STORAGE`)
    - **Why separate storage:** Main storage account has `--allow-shared-key-access false`, but Function runtime requires shared key access for its internal operations (host.json, triggers, bindings state)
  - Creates `leases` container in Cosmos DB (partition key `/id`, 400 RU/s throughput)
  - Creates Function App (Linux, Python 3.11, Consumption plan) with system-assigned MI
  - Configures app settings:
    - `COSMOS_ENDPOINT` — from Cosmos account
    - `COSMOS_DATABASE` = `email-analyzer-db`
    - `COSMOS_CONTAINER` = `emails`
    - `COSMOS_CONNECTION__accountEndpoint` — for trigger binding with MI auth (double underscore pattern)
    - `AzureWebJobsStorage` — connection string to Function storage account
  - Assigns `Cosmos DB Built-in Data Contributor` role (00000000-0000-0000-0000-000000000002) to Function MI
  - Deploys function code using `func azure functionapp publish` (if Azure Functions Core Tools installed)
- **Cosmos DB trigger binding:**
  - Uses `@app.cosmos_db_trigger` decorator with `connection="COSMOS_CONNECTION"`
  - Connection setting `COSMOS_CONNECTION__accountEndpoint` enables managed identity auth (no connection string)
  - `create_lease_container_if_not_exists=True` for automatic lease container creation
- **Pattern:** Azure Function change feed processor complements Logic App — Logic App handles email intake/classification, Function handles post-classification agent processing
- **Security:** Zero connection strings for Cosmos DB — managed identity everywhere (except Function internal storage which requires shared key per Azure Functions runtime requirement)
- **Key files:** `azure-function/function_app.py`, `infrastructure/deploy-azure-function.sh`
- **Decision doc:** `.squad/decisions/inbox/ripley-azure-function.md`

### Session: Consumption → App Service Plan Migration
- **Problem:** `az functionapp create` on Consumption plan always tries to create file shares via shared keys. Azure Policy enforces `allowSharedKeyAccess=false`, causing 403 errors. Pre-creating file shares via ARM API doesn't help because the CLI still attempts its own shared-key operations.
- **Solution:** Switched to App Service Plan (B1, Linux) which stores code locally on the VM — no file share dependency at all.
- **Changes to `infrastructure/deploy-azure-function.sh`:**
  - Added `APP_SERVICE_PLAN` config variable (default: `email-analyzer-func-plan`)
  - Added `az appservice plan create --sku B1 --is-linux` step
  - Replaced `--consumption-plan-location` with `--plan` in `az functionapp create`
  - Removed file share pre-creation (`az storage share-rm create`)
  - Removed `WEBSITE_CONTENTSHARE` and `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING__accountName` settings
  - Added cleanup of legacy Consumption plan settings
- **Architecture insight:** When Azure Policy blocks shared keys, Consumption plan is NOT viable. App Service Plan B1 is the safest fallback — Flex Consumption might work but has limited region availability.
- **Key files:** `infrastructure/deploy-azure-function.sh`
- **Decision doc:** `.squad/decisions/inbox/ripley-appservice-plan.md`

### Session: Add Mortgage Inquiry Classification Category
- **Task:** Add new `mortgage_inquiry` classification category to EmailClassifierAgent
- **Changes made:**
  1. `foundry-agent/create_classifier_agent.py`:
     - Added `mortgage_inquiry` category after `sales_inquiry` in Categories section (line 46-47)
     - Description covers: customer interest in mortgages, inquiries about rates/terms/conditions/requirements, mortgage product applications
     - Added example email in Examples section (line 88-90): customer asking about mortgage rates and application requirements
     - High confidence score (96) due to explicit intent
- **Pattern:** New classification categories follow the same structure: (1) category definition with dash bullet, (2) concise description covering inquiry types, (3) realistic example with JSON response
- **Impact:** EmailClassifierAgent now has 14 classification types (added to previous 13). No Logic App or web app changes needed — agent behavior updates automatically on next deployment.
- **Key file:** `foundry-agent/create_classifier_agent.py`

---
## Learnings

### Session: Rule 3 — Component-Based IBAN Validation
- **Task:** Update bank account validation rule to validate IBAN as individual components instead of a single string
- **Change:** Rule 3 in `foundry-agent/create_validation_agent.py` VALIDATION_INSTRUCTIONS now requires five separate fields: Iban (country+check), Bank (4-digit), Branch (4-digit), DC (2-digit control), Account (number)
- **Pattern:** When changing agent prompt instructions, update three spots: rule description, status/detail guidance text, and the example output JSON to stay consistent
- **CSV unchanged:** CSV (Código Seguro de Verificación) validation remains alongside the bank components
- **Key file:** `foundry-agent/create_validation_agent.py`

### Session: PersonalInformationValidationAgent Implementation
- **Task:** Create validation agent and integrate with Azure Function to validate personal documents from emails
- **Solution:** Created `PersonalInformationValidationAgent` following exact pattern as `EmailClassifierAgent`
  - Agent script: `foundry-agent/create_validation_agent.py`
  - Validates IRPF and Vida Laboral documents against 4 business rules:
    1. Required Documents (both IRPF and Vida Laboral present)
    2. Name Consistency (full name matches across documents)
    3. Bank Account & CSV (IBAN and CSV code in IRPF)
    4. CEA Code Consistency (same CEA across all pages in Vida Laboral)
  - Returns structured JSON: `{"title": "Validation", "statements": [{"rule": "...", "status": "pass|fail", "detail": "..."}]}`
- **Integration:** Updated Azure Function to call agent instead of mock data
  - Used `urllib.request` for HTTP POST to Responses API (consistent with invoke_agent.py pattern)
  - Managed identity auth with `credential.get_token("https://ai.azure.com/.default")`
  - Request URL: `{FOUNDRY_AGENT_ENDPOINT}/applications/{VALIDATION_AGENT_APP_NAME}/protocols/openai/responses?api-version=2025-11-15-preview`
  - Payload: `{"input": "<document_data_as_json_string>"}`
  - Error handling: captures HTTP errors and JSON parse errors, returns structured error in agentResult
  - Status update: "Processed by agent" on success, "Agent processing failed" on error
- **Configuration:**
  - Added `FOUNDRY_AGENT_ENDPOINT` and `VALIDATION_AGENT_APP_NAME` env vars to function app settings
  - Default app name: `personal-info-validator`
  - Updated `infrastructure/deploy-azure-function.sh` to set these during deployment
- **Publishing:** Updated `publish_agent.sh` to document how to publish validation agent by setting `APPLICATION_NAME=personal-info-validator` and `AGENT_NAME=PersonalInformationValidationAgent`
- **Pattern:** Same agent creation pattern (AIProjectClient, PromptAgentDefinition, async/await), same invocation pattern (Responses API, managed identity), makes adding new agents trivial
- **Key files:** `foundry-agent/create_validation_agent.py`, `azure-function/function_app.py`, `infrastructure/deploy-azure-function.sh`, `foundry-agent/publish_agent.sh`

---
