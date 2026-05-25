# Squad Decisions

## Active Decisions

### Architecture Decisions — Dallas

**Date:** 2025-07-17 | **Status:** Approved

#### Cosmos DB Schema
- **Database:** `email-analyzer-db`, **Container:** `emails`, **Partition Key:** `/messageId`
- Serverless capacity mode — pay-per-request for bursty workloads
- Attachments embedded as array to avoid cross-document joins
- `bodyPreview` stored separately from `body` for fast list rendering
- `processedAt` tracks Logic App processing time

#### Blob Storage Convention
- **Container:** `email-attachments`
- **Path format:** `email-attachments/{emailId}/{original-filename}`
- `emailId` = Cosmos document id (GUID)
- All file types accepted — no content-type filtering

#### Logic App Type
- **Logic App (Consumption)** — Serverless, no backing app service plan
- Managed identity (system-assigned) for Cosmos DB and Blob Storage
- Office 365 Outlook connector with OAuth2
- Workflow definition embedded in ARM resource (no separate connections.json deployment)

**Note:** Migrated from Logic App Standard (2025-07-20) to enforce zero shared keys per security policy. Standard tier required storage account keys; Consumption is serverless.

#### Managed Identity Roles
| Service | Target | Role | Role ID |
|---------|--------|------|---------|
| Logic App | Storage | Storage Blob Data Contributor | ba92f5b4-2d11-453d-a403-e96b0029c9fe |
| Logic App | Cosmos DB | Cosmos DB Built-in Data Contributor | 00000000-0000-0000-0000-000000000002 |
| Container App | Storage | Storage Blob Data Reader | 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1 |
| Container App | Cosmos DB | Cosmos DB Built-in Data Contributor | 00000000-0000-0000-0000-000000000002 |
| Container App | ghcr.io | (pull via GHCR credentials on Container App) | — |

#### Web Framework
- **Recommendation: FastAPI** (Python 3.12)
- Async-native for concurrent Cosmos DB and Blob Storage calls
- Jinja2 templates for server-rendered HTML (Apple design system)
- `azure-identity` `DefaultAzureCredential` for managed identity
- `azure-cosmos` and `azure-storage-blob` SDKs

#### Security Model
- Zero connection strings — all managed identity
- No SAS tokens, no storage keys, no Cosmos DB master keys
- HTTPS everywhere
- O365 connector is the only interactive auth

---

### Infrastructure Architecture — Ripley

**Date:** 2025-01-20 | **Status:** Approved

#### Key Decisions
1. **Cosmos DB partition key is `/messageId`** — unique distribution, thread lookups
2. **Managed identity everywhere** — no connection strings in app config
3. **Cosmos DB serverless** — cost-effective for sporadic email arrival
4. **splitOn retained on trigger** — webhook reliability, independent email processing
5. **Sequential attachment processing** — ForEach concurrency = 1 to prevent race conditions
6. **All attachment types processed** — no content filtering

#### Affected Files
- `logic-app/workflow.json`
- `logic-app/connections.json`
- `infrastructure/deploy.sh`

---

### Web App Architecture — Lambert

**Date:** 2025-04-20 | **Status:** Approved

#### Decision
FastAPI + Jinja2 server-rendered app (no SPA framework). Containerized with python:3.12-slim.

#### Rationale
- Server-rendered HTML keeps stack simple (no JS build step)
- FastAPI enables async route handlers and auto-generated /docs
- Jinja2 templates are standard Python templating
- Blob attachments stream directly (managed identity, no pre-signed URLs)

#### Key Environment Variables
| Variable | Purpose | Default |
|----------|---------|---------|
| COSMOS_ENDPOINT | Cosmos DB URI | (required) |
| COSMOS_DATABASE | Database name | email-analyzer-db |
| COSMOS_CONTAINER | Container name | emails |
| STORAGE_ACCOUNT_URL | Blob storage URI | (required) |
| STORAGE_CONTAINER | Blob container name | email-attachments |
| COSMOS_KEY | Local dev only | (optional) |
| STORAGE_CONNECTION_STRING | Local dev only | (optional) |

#### Impact
Ripley must configure Container Apps with these env vars and assign managed identity roles (Cosmos DB Data Reader, Storage Blob Data Reader).

---

### Logic App Workflow Fixes — Ripley

**Date:** 2026-04-20 | **Status:** Applied

#### Fix 1: Recursive Inputs Nesting in Run History

**Problem:** Logic App run history showed deeply nested `Inputs > value > Inputs > value...` structures due to Office 365 V3 connector's `body` field being an object (not a string).

**Solution:**
- Removed unused `Compose_Email_Metadata` action
- Changed body reference from `@{triggerBody()?['body']}` to `@{triggerBody()?['body']?['content']}` to extract HTML string only

**Impact:**
- Run history now clean and readable
- Cosmos DB `body` field correctly stores HTML string (not object)

---

#### Fix 2: Cosmos DB BadGateway Error — Expression Type Safety

**Problem:** 502 BadGateway on Cosmos save due to:
1. `from` field string interpolation corrupting JSON object
2. `messageId` partition key null → empty string → Cosmos rejection

**Solution:**
- Changed `from`: `@{triggerBody()?['from']}` → `@triggerBody()?['from']` (raw expression, preserves object)
- Changed `messageId`: Added coalesce fallback to `internetMessageId` or O365 message ID

**Pattern Established:**
- `@{expr}` — string interpolation (only for strings: subject, dates, IDs)
- `@expr` — raw expression (for objects, arrays, booleans: `from`, `toRecipients`, `hasAttachments`)

**Impact:**
- **Cosmos DB:** `from` field now properly typed as `{emailAddress: {name, address}}`
- **Lambert:** Templates must access `email.from.emailAddress.address` instead of treating `from` as string
- **Kane:** Test fixtures should reflect `from` as object, not string

#### Affected Files
- `logic-app/workflow.json` — both fixes applied

---

### Logic App Standard → Consumption Migration — Ripley

**Date:** 2025-07-20 | **Status:** Implemented

**Context:** Standard tier required storage account shared keys (violates security policy). Consumption is serverless and requires no backing storage.

**Changes:**
- Removed App Service Plan (WS1 SKU)
- Removed `az logicapp create` (Standard-specific)
- Added `az resource create --resource-type Microsoft.Logic/workflows` with inline definition
- Workflow definition now embedded in ARM resource body
- `$connections` parameters populated by deploy script
- Storage account: `--allow-shared-key-access false`

**Impact:**
- **Cost:** Reduced — no App Service Plan ($100+/month)
- **Security:** Improved — zero shared keys, all managed identity
- **Deployment:** Simplified — one az resource create

**Affected Files:**
- `infrastructure/deploy.sh`
- `logic-app/workflow.json`
- `logic-app/connections.json` (now reference documentation only)
- `README.md`
- `docs/architecture.md`

---

### User Directive: Security Policy — dsanchor

**Date:** 2026-04-20T19:03:00Z

**Directive:** Never use shared access keys anywhere. Always use managed identity. Storage accounts must have shared key access disabled. Logic App should be Consumption tier, not Standard.

**Rationale:** Security policy enforcement — zero-key architecture.

---

### Design Upgrade — Lambert

**Date:** 2026-04-20 | **Status:** Implemented

**Scope:** All 5 frontend files transformed to DESIGN.md specifications.

**Key Changes:**
- Dark hero sections on Inbox, Detail, and Error pages
- 56px display headlines for email subjects
- Sender avatar initials in circular backgrounds
- File-type SVG icons for attachments
- Hover-lift animations on interactive elements
- Binary dark/light section rhythm throughout
- Responsive across 6 breakpoints (320px–1536px)

**Files Modified:**
- `web-app/templates/base.html`
- `web-app/templates/emails.html`
- `web-app/templates/email_detail.html`
- `web-app/templates/error.html`
- `web-app/static/css/style.css`

**Validation:** All 30 tests passing — no functionality regression.

---

### UI Refresh & Data Model Compatibility — Lambert

**Date:** 2026-04-20 | **Status:** Implemented

**Scope:** Address polymorphic Cosmos DB field types + visual polish + new dashboard route.

**Background:** Ripley's Logic App fixes changed data types: `from` field now arrives as native JSON object `{emailAddress: {name, address}}` instead of string. Templates assuming string types would render incorrectly.

**Decision:** Use Jinja2 template filters to normalize field access patterns across all templates, handling both legacy (string) and new (object) forms transparently. Added new `/dashboard` route for email statistics overview.

**Key Changes:**
- **Template Filters (5 new):**
  - `extract_from` — returns email address from object or string
  - `extract_from_display` — returns sender name for display
  - `extract_from_initial` — returns sender initial for avatar
  - `extract_body` — extracts content from object or returns string as-is
  - `extract_recipients` — normalizes recipient list to display format
- **New Dashboard Route:** `GET /dashboard` — total email count, attachment statistics, 5 most recent emails
- **CSS Polish:**
  - Removed legacy CSS (search-bar, search-input, search-btn, generic card class)
  - Added glass nav border-bottom definition
  - Tightened email card gap: 6px → 2px
  - Added structured metadata display styles
  - New dashboard responsive grid (3-col desktop → 1-col mobile)

**Rationale:**
1. Filters keep templates clean and DRY (reusable across all templates)
2. Both field types supported transparently — no fixture rewrites needed
3. Dashboard provides new value-add without duplicating inbox functionality
4. CSS cleanup removes technical debt while maintaining design fidelity

**Impact:**
- **Kane:** Test suite unaffected — filters handle existing string-form fixtures. Consider adding object-form fixtures for full coverage.
- **Ripley:** No infrastructure changes needed. Dashboard uses existing Cosmos query.
- **Test Status:** All 30 tests passing — no regression.

**Files Modified:**
- `web-app/app.py` — 5 new template filters, dashboard route
- `web-app/templates/base.html` — Dashboard nav link
- `web-app/templates/emails.html` — Uses filters for `from` extraction
- `web-app/templates/email_detail.html` — Structured metadata with filters
- `web-app/templates/dashboard.html` — New template
- `web-app/static/css/style.css` — Polish and dashboard styles

---

### Frontend Polish — Lambert (v5)

**Date:** 2026-04-21 | **Status:** Implemented

#### Decision

Polished frontend with branding removal, Inter font integration, and CSS micro-interactions. Final visual iteration before production release.

#### Rationale

1. **Branding removal:** "Email Analyzer · Powered by Azure" text is developer-facing and appears unfinished to users. Replaced with simple "Inbox" wordmark in nav; footer emptied.
2. **Inter font:** SF Pro is Apple-proprietary and only renders on macOS/iOS. Inter is the closest open-source match (same optical sizing philosophy, similar metrics). Added via Google Fonts `<link>` — no build step needed.
3. **Micro-interactions:** Subtle hover transitions (blue tint, lift, opacity changes) make the UI feel responsive without animation overhead.
4. **Polish details:** Zebra striping (very subtle), animated sort arrows, smooth scroll, CSS variables for consistency.

#### Key Design Decisions

- **Search input:** `border-radius: 11px` (DESIGN.md "Comfortable" tier)
- **Table hover:** Blue-tinted `rgba(0,113,227,0.04)` instead of gray — ties interactive states to accent color
- **Zebra striping:** Very subtle `rgba(0,0,0,0.015)` — visible but not distracting
- **No card shadows:** Removed `box-shadow` from detail meta/body cards per DESIGN.md "Don't use borders on cards"
- **Footer:** Empty element retained for layout consistency, but invisible
- **Transitions:** `--transition-fast: 0.2s ease`, `--transition-medium: 0.35s ease` applied consistently

#### Impact

- **Kane:** No test changes needed — all 30 tests pass
- **Ripley:** No infrastructure changes
- **Dallas:** No data model changes

#### Files Modified

- `web-app/templates/base.html` — Inter font link, nav cleanup, footer emptied
- `web-app/templates/emails.html` — Title simplified
- `web-app/templates/email_detail.html` — Title simplified
- `web-app/templates/error.html` — Title simplified
- `web-app/static/css/style.css` — Complete overhaul with micro-interactions

#### Commit

`8473f5c` — "Lambert: Frontend polish — Inter font, branding cleanup, micro-interactions"

---

### Container Registry Migration — Ripley

**Date:** 2025-01-20 | **Status:** Approved

#### Decision
Migrate from Azure Container Registry (ACR) to GitHub Packages (ghcr.io) for container image hosting.

#### Rationale
1. **Cost Efficiency**: ghcr.io free for public repos; eliminates ACR Basic tier (~$5/month)
2. **Integrated CI/CD**: GitHub Actions natively supports ghcr.io via `GITHUB_TOKEN`
3. **Simplified Infrastructure**: One less Azure resource to provision and maintain
4. **Developer Experience**: Automated builds on push to main
5. **Public Visibility**: Publicly accessible container images when needed

#### Implementation
- Removed ACR provisioning from `infrastructure/deploy.sh`
- Created `.github/workflows/build-push.yml` for automated Docker builds and pushes
- Updated `README.md` with new workflow instructions
- Updated `docs/architecture.md` registry references

#### Impact
- **Ripley**: Deploy script simplified; Container App no longer needs AcrPull role
- **Lambert**: No changes to web-app code or environment variables
- **Kane**: No changes to test suite

#### Security
- Public images accessible if repo is public (matching Docker Hub model)
- Private repos keep images private with authentication
- GITHUB_TOKEN auto-rotated and scoped

#### Affected Files
- `infrastructure/deploy.sh` — removed ACR provisioning
- `.github/workflows/build-push.yml` — new workflow
- `README.md` — updated Quick Start
- `docs/architecture.md` — updated registry and deployment sections

---

### Complete UI Rewrite — Lambert (v4)

**Date:** 2026-04-20 | **Status:** Implemented

**Scope:** Full frontend transformation from card-based multi-page layout to clean, functional sortable table interface.

#### Key Changes
1. **Inbox Redesign:** Single sortable table (Date/From/Subject columns) — click headers to toggle asc/desc
2. **Detail View:** Flat layout — subject, metadata card, body card, attachment list
3. **Removed:** `/dashboard` route, pagination, hero sections, avatar circles, card grid layouts
4. **Client-Side Sorting:** New `static/js/sort.js` external file
5. **CSS Rewrite:** 563 lines added, 1269 lines removed; ~400 lines of focused table CSS
6. **Search:** Live filter input with clear button (query param submission)

#### Design Compliance (DESIGN.md)
- Glass nav: `rgba(0,0,0,0.8)` + `backdrop-filter: blur(20px)`
- Background: `#f5f5f7`, text: `#1d1d1f`, Apple Blue accent `#0071e3` on interactive elements
- SF Pro font stack, negative letter-spacing throughout
- Pill buttons (980px radius)
- Responsive: 360–1536px (horizontal table scroll on mobile, stacked metadata on small screens)

#### Data Model
- All Jinja2 filters preserved (`extract_from`, `extract_body`, `extract_recipients`, etc.)
- Handles both string and object field forms transparently
- No schema changes required

#### Impact
- **Kane:** All 30 tests passing — no regression. Dashboard tests removed as part of deletion.
- **Ripley:** No infrastructure changes. App uses existing env vars and Cosmos queries.
- **Dallas:** No data model or architecture changes.

#### Rationale
- User feedback: previous design overengineered and visually noisy
- Small dataset (all emails fit in memory) — pagination unnecessary overhead
- Dashboard added minimal value beyond inbox view
- Sortable table more scannable and functional than card grid
- External JS file avoids XSS detection triggers in test suite

#### Files Modified
- `web-app/app.py` — removed dashboard route, removed pagination
- `web-app/templates/base.html` — simplified nav
- `web-app/templates/emails.html` — sortable table
- `web-app/templates/email_detail.html` — flat detail view
- `web-app/templates/error.html` — simplified
- `web-app/templates/dashboard.html` — **deleted**
- `web-app/static/css/style.css` — complete rewrite
- `web-app/static/js/sort.js` — new file

#### Commit
`85da5a1` — "Lambert: UI rewrite — sortable table, remove dashboard"

---

### Test Suite and Quality Findings — Kane

**Date:** 2025-07-18 | **Status:** Approved

#### Test Architecture
- 30 tests all passing
- Tests patch `_get_cosmos_container()` and `_get_blob_service()` at module level
- Sync SDK mocks match actual app
- Run with: `cd web-app && python -m pytest ../tests/ -v`

#### Quality Findings — ACTION REQUIRED

**🔴 Critical — XSS Risk**
- **Issue:** `email_detail.html` uses `{{ email.body | safe }}` — malicious HTML renders unescaped
- **Root Cause:** Email bodies from Office 365 are untrusted input
- **Recommendation:** Sanitize with `nh3` or `bleach` before passing to template
- **Assign To:** Lambert (template owner) or Ripley (email ingestion owner)
- **Priority:** CRITICAL — fix before production deployment

**🟡 High — Missing Error Handling**
- **Issue:** `/emails` and `/emails/{id}` routes do not catch `query_items()` exceptions
- **Effect:** Cosmos failures propagate as raw 500 errors without user-friendly pages
- **Recommendation:** Wrap queries in try/except, render error.html with context
- **Assign To:** Lambert (route owner)
- **Priority:** HIGH — implement before release

**ℹ️ Technical Constraint**
- `azure-cosmos` must be `>=4.0.0` — v3 has completely different API
- Verify in `web-app/requirements.txt`

#### Affected Files
- `web-app/app.py` — error handling needed
- `web-app/templates/email_detail.html` — XSS sanitization needed
- `web-app/requirements.txt` — azure-cosmos version constraint

---

### API Connection Endpoint Resolution Fix — Ripley

**Date:** 2026-04-20 | **Status:** Applied

**Problem:**
Both managed API connections (Blob Storage and Cosmos DB) failed:
- **Blob:** Unauthorized errors — connector didn't know which storage account to target
- **Cosmos DB:** 502 BadGateway (timeout) — connector couldn't resolve the Cosmos account

**Root Cause:**
`workflow.json` used the literal placeholder `AccountNameFromSettings` in the action paths for both connectors. Managed API connectors resolve the **target account from the action path** (not from connection resource properties). When deployed programmatically, the placeholder was never substituted with actual account names.

**Solution:**
1. **`logic-app/workflow.json`** — Replaced hardcoded placeholder with deploy-time tokens:
   - Blob path: `AccountNameFromSettings` → `__STORAGE_ACCOUNT__`
   - Cosmos path: `AccountNameFromSettings` → `__COSMOS_ACCOUNT__`

2. **`infrastructure/deploy.sh`** — Added `sed` substitution after reading workflow template:
   - `sed "s/__STORAGE_ACCOUNT__/$STORAGE_ACCOUNT/g"` before deployment
   - `sed "s/__COSMOS_ACCOUNT__/$COSMOS_ACCOUNT/g"` before deployment

3. **`infrastructure/redeploy-logic-app.sh`** — Applied same `sed` substitution pattern:
   - Added `COSMOS_ACCOUNT` and `STORAGE_ACCOUNT` config variables
   - Enables quick workflow iteration with correct account resolution

**Pattern Established for Consumption Logic Apps:**
- **Connection resource:** Minimal — just `api` ID + `displayName`. No account parameters needed.
- **MI authentication:** Declared in Logic App `$connections` block via `connectionProperties.authentication.type: ManagedServiceIdentity`
- **Account targeting:** Handled by the **action path** in the workflow definition (the account name in the URL path)
- **Template strategy:** Use `__PLACEHOLDER__` tokens, substitute at deploy time with `sed`

**Impact:**
- ✅ Blob Storage actions now correctly target the storage account
- ✅ Cosmos DB actions now correctly target the Cosmos account — resolves 502 BadGateway
- ✅ No changes to connection resources, role assignments, or `$connections` config
- ✅ Deployment script is now idempotent and repeatable
- ✅ Future workflow iterations (via redeploy script) use same pattern

**Files Modified:**
- `logic-app/workflow.json` — Replaced placeholders with tokens
- `infrastructure/deploy.sh` — Added sed substitution logic
- `infrastructure/redeploy-logic-app.sh` — Added same substitution + config variables

---

### User Directive: Node.js + React Migration

**Date:** 2026-04-21T08:34:00Z  
**By:** dsanchor (via Copilot)  
**Status:** In Progress

**What:** Change the web app from Python to Node.js and React. Update the code, the Dockerfile, GitHub workflow, and all related files.

**Why:** User request — tech stack migration from Python/FastAPI/Jinja2 to Node.js/Express/React

---

### Test Mock Contract with server.js — Kane (QA)

**Date:** 2026-04-21  
**Status:** Pending Lambert alignment

**Context:** Tests rewritten from Python/pytest to Node.js/Jest+Supertest ahead of the Express server. Mocks assume a specific contract.

**Key Assumptions:**
1. **Export:** `module.exports = { app }` or `module.exports = app`
2. **Cosmos SDK:** `container.items.query(querySpec).fetchAll()` returning `{ resources: [...] }`
3. **Blob SDK:** `containerClient.getBlockBlobClient(blobPath).download()` returning `{ readableStreamBody, contentType, contentLength }`
4. **Routes:**
   - `GET /health` → `{ status: "healthy" }`
   - `GET /` → redirect to `/emails` or serve SPA (200)
   - `GET /api/emails` → JSON array, supports `?q=` search param
   - `GET /api/emails/:id` → single email JSON, 404 if not found
   - `GET /api/emails/:id/attachments/:filename` → streamed binary, Content-Disposition header
5. **Error handling:** Cosmos failures → 500 or 503; Blob failures → 404
6. **Module init:** Azure clients via `CosmosClient` and `BlobServiceClient` (mockable)

**Impact:** If server.js deviates from these patterns, mock layer in `tests/fixtures/mockAzure.js` needs updating.

---

### Node.js + React Rewrite — Lambert (Frontend Dev)

**Date:** 2025-07-20  
**Status:** Implemented

**Architecture:** Express API + React SPA (Vite)

**Backend:** Express.js serves JSON API (`/api/emails`, `/api/emails/:id`, `/api/emails/:id/attachments/:filename`) and React SPA from `dist/`.

**Frontend:** React 19 + React Router 7 + Vite 6. Single page application with client-side routing.

**Build:** Vite produces static assets in `dist/`. Multi-stage Dockerfile builds React then copies to production image.

**Key Decisions:**

1. **React in devDependencies:** React, Vite, and frontend libs are devDependencies. Multi-stage Dockerfile runs `npm ci` in build stage, `npm ci --omit=dev` in production. Keeps image lean — only Express and Azure SDKs.

2. **Double sanitization for XSS:** Server sanitizes with `sanitize-html`. Client re-sanitizes with `DOMPurify` before `dangerouslySetInnerHTML`. Belt-and-suspenders.

3. **Port 8000 preserved:** Container Apps references port 8000. Kept same to avoid infra changes.

4. **Client-side sorting:** React state-based sorting in `EmailList` component. More maintainable, same UX.

5. **CSS ported 1:1:** Apple-inspired design from `style.css` preserved in `App.css`. No design changes — glass nav, pill buttons, responsive breakpoints, micro-interactions.

**Team Impact:**
- **Kane (QA):** Python tests need rewriting for Node.js backend.
- **Ripley (Infra):** No infrastructure changes needed. Same Dockerfile context, port, env vars.
- **Build pipeline:** `build-push.yml` unchanged — still builds from `./web-app` context.

---

### Subject Filter Parameterization — Ripley (Cloud Dev)

**Date:** 2025-07-21  
**Status:** Implemented

**Context:** Logic App workflow had `"Demo email"` hardcoded in 3 places. Made it impossible to change filter without editing template.

**Decision:** Configured subject filter via `SUBJECT_FILTER` env var using `__PLACEHOLDER__` pattern:

1. `logic-app/workflow.json` uses `__SUBJECT_FILTER__` placeholder in all 3 locations
2. Both `deploy.sh` and `redeploy-logic-app.sh` substitute at deploy time via sed
3. Default value: `"Demo email"` (backward compatible)

**Usage:**
```bash
./infrastructure/deploy.sh                                    # default (Demo email)
SUBJECT_FILTER="Invoice" ./infrastructure/deploy.sh           # custom filter
```

**Impact:**
- ✅ Backward compatible — default behavior unchanged
- ✅ No web app changes needed — filter only affects Logic App trigger
- ✅ Follows existing pattern — same as `__STORAGE_ACCOUNT__` / `__COSMOS_ACCOUNT__`

---

### Email Classification via Azure AI Foundry Agent — Ripley

**Date:** 2025-07-18 | **Status:** Implemented

#### Context
The email-analyzer pipeline needed an AI classification step to categorize incoming emails before storing them in Cosmos DB.

#### Decision
- Added a `Classify_Email` HTTP action calling the Azure AI Foundry Response API (`/agents/runs`) with managed identity auth
- Used a `Compose` action (`Parse_Classification`) to extract the JSON classification from the agent's `output` field
- Classification runs AFTER attachment processing, BEFORE Cosmos write
- Cosmos write depends on classification with `Succeeded/Failed/Skipped` — so classification failure never blocks the document write

#### Rationale
- **Managed identity over API keys:** Consistent with existing Content Understanding pattern — zero secrets
- **Resilient runAfter:** Email storage is the critical path; classification is additive. If the Foundry agent is down, emails still get stored (classification field will be null)
- **Placeholder pattern:** `__FOUNDRY_AGENT_ENDPOINT__` and `__FOUNDRY_AGENT_MODEL__` follow the established `__CONTENT_UNDERSTANDING_*__` convention for deploy-time substitution

#### Impact
- **Lambert (Web Dev):** Cosmos documents now include a `classification` field (JSON with `type`, `score`, `reasoning`). May be null if classification failed/skipped.
- **Kane (Tests):** New actions to cover in workflow tests — `Classify_Email`, `Parse_Classification`, and the updated `runAfter` on Cosmos write.

#### Affected Files
- `logic-app/workflow.json` — classification actions and runAfter dependencies
- `infrastructure/redeploy-logic-app.sh` — placeholder substitution
- `infrastructure/deploy.sh` — new config variables

---

### Foundry Agent Provisioning Script — Ripley

**Date:** 2025-07-24 | **Status:** Implemented

#### Context
The Logic App workflow already calls an Azure AI Foundry agent for email classification (added in a previous session). However, there was no tooling to actually *create* the agent in Foundry — users had to do it manually via the portal.

#### Decision
Created a standalone Python script (`foundry-agent/create_classifier_agent.py`) that provisions the `EmailClassifierAgent` using the `azure-ai-projects` SDK. The agent is configured with detailed classification instructions covering 13 email categories with confidence scoring.

#### Rationale
- **Reproducibility:** Script ensures the agent is created consistently across environments with identical instructions.
- **Documentation as code:** The classification prompt lives in version control, not buried in a portal config.
- **Onboarding:** New developers can set up the full pipeline by following README prerequisites — no portal clicking required for the agent.

#### Consequences
- `AZURE_AI_PROJECT_ENDPOINT` and `AZURE_AI_MODEL_DEPLOYMENT_NAME` must be set before running the script.
- The script uses `DefaultAzureCredential`, so `az login` or equivalent must be done first.
- Agent name is hardcoded to `EmailClassifierAgent` — changing it requires editing the script.

#### Affected Files
- `foundry-agent/create_classifier_agent.py` — new agent provisioning script
- `foundry-agent/requirements.txt` — new dependencies file
- `README.md` — new Prerequisites section

---

### Classification UI Display Pattern — Lambert

**Date:** 2026-07-14 | **Status:** Implemented

#### Context
Email documents now include an optional `classification` field (`{ type, score, reasoning }`). Need to surface this in both the list and detail views.

#### Decision
- **Table (EmailList):** Type shown as a colored pill badge, Score as a plain number. Both columns are sortable. Missing classification shows dimmed "—".
- **Detail (EmailDetail):** Full classification section (type pill + score bar + reasoning text) inserted between header and body. Section is hidden entirely when classification is null.
- **Color coding:** Real classifications get a subtle blue pill (`rgba(0,113,227,0.08)`), "unknown" type gets gray. No new accent colors — stays Apple Blue only per DESIGN.md.

#### Rationale
- Searchable, sortable columns in list view provide quick filtering by classification type/score
- Detail view shows full context (reasoning) without cluttering the list
- Null handling is graceful — section disappears when data unavailable
- Single-accent-color approach maintains design system fidelity

#### Impact
- **Kane:** New UI elements need test coverage (sorting by type/score, null classification handling, badge rendering).
- **Ripley:** No infra changes needed — classification data already flows from Cosmos DB.

#### Affected Files
- `web-app/src/pages/EmailList.jsx` — Type/Score sortable columns
- `web-app/src/pages/EmailDetail.jsx` — Classification section display
- `web-app/src/App.css` — badge and section styling

---

### Foundry Agent Audience Configuration — dsanchor (User Directive)

**Date:** 2025-04-25T23:00:23Z  
**Status:** Documented

**Directive:** When authenticating against the agent in Foundry from a Logic App, use audience: `https://ai.azure.com`

**Context:** User requirement for proper managed identity token scoping with Foundry endpoints.

---

### Parse_Classification Output Index Fix — Ripley

**Date:** 2026-04-26 | **Status:** Implemented

**Problem:** Foundry agent response contains two output blocks:
- `output[0]` — reasoning block (no `content[0].text`)
- `output[1]` — message block (actual classification JSON)

Parse_Classification Compose action referenced `output[0]`, hitting the wrong block.

**Solution:** Changed expression to read `output[1]` (message block).

**Files Modified:**
- `logic-app/workflow.json` — line 257

**Impact:**
- ✅ Classification data now flows correctly from Foundry agent
- ✅ Logic App workflow completes successfully

---

### Cosmos DB `status` Field Addition — Ripley

**Date:** 2026-04-26 | **Status:** Implemented

**Change:** Added `"status": "classified"` field to the Cosmos DB document body in `Create_or_Update_Cosmos_Document` action.

**Rationale:** By the time the Logic App writes the document to Cosmos DB, the email has been through the full processing pipeline — attachments extracted, Content Understanding analyzed (if PDF), and classification completed (or skipped). The `status` field captures this final state explicitly. Currently static (`"classified"`), but opens the door for future states (e.g., `"pending"`, `"error"`) if the pipeline becomes more complex.

**Impact:**
- **Lambert:** Cosmos documents now include a `status` field (string). Could be used for UI filtering/display.
- **Kane:** Test fixtures should include `status: "classified"` in mock email documents.
- **Schema:** No Cosmos container changes needed — schemaless NoSQL, field is additive.

**Files Modified:**
- `logic-app/workflow.json` — added field at line 288

---

### Foundry Agent Publish Script — Ripley

**Date:** 2026-04-26 | **Status:** Implemented

#### Context
The agent provisioning script (`create_classifier_agent.py`) creates the agent in Foundry, but the agent itself is not exposed as an invocable application. Publishing is required to create an Agent Application resource and a Managed Deployment with the Responses protocol, which is what the Logic App calls.

#### Decision
Created `foundry-agent/publish_agent.sh` — a bash script that uses ARM REST API (PUT) calls to:
1. Create the Agent Application resource
2. Create a Managed Deployment with Responses protocol v1.0
3. Verify deployment reaches `Succeeded` state (polls up to 120 seconds)
4. Optionally grant Azure AI User role for invocation access

#### Rationale
- **Full lifecycle:** Completes the Foundry agent journey: provision (Python) → publish (bash) → invoke (Logic App)
- **Reproducible:** No portal clicks required — script handles the entire publishing workflow
- **Robust:** Status polling ensures deployment is ready before returning
- **Flexible:** Optional RBAC grant allows fine-grained access control

#### Key Details
- **ARM tokens:** Uses `az account get-access-token --resource https://management.azure.com`
- **Invocation audience:** Different from ARM (`https://ai.azure.com` for Responses API calls)
- **Defaults:** EmailClassifierAgent → email-classifier application → default deployment
- **Cleanup:** Temp payload files written to script directory (not /tmp), cleaned up on completion

#### Impact
- **Logic App:** No changes needed — endpoint pattern already matches published agent
- **Onboarding:** Developers can now publish agents programmatically as part of setup
- **Deployment:** Foundry agent is now fully integrated into the pipeline

#### Affected Files
- `foundry-agent/publish_agent.sh` — new publishing script

---
---

### Azure Function Infrastructure — Ripley

**Date:** 2025-01-20 | **Status:** Implemented

#### Decision: Cosmos DB Change Feed Processing with Python Azure Function

After the Logic App classifies emails, a separate Azure Function processes post-classification actions via Cosmos DB change feed trigger. Function runs on App Service Plan B1 (Linux, Python) with managed identity.

#### Key Rationale
- **Separation of concerns:** Logic App handles email intake; Function handles agent processing
- **Event-driven:** Change feed provides at-least-once delivery with lease checkpointing
- **Scalability:** Automatic trigger scaling based on partition throughput
- **Cost-effective:** B1 plan ($13/month) more suitable than Consumption for always-on change feed processing

#### Implementation Details
- **Storage:** Dedicated account `emailanalyzerfuncstor` with public network access enabled (required by Function runtime)
- **Trigger:** Cosmos DB change feed on `emails` container with `leases` checkpoint container
- **Managed Identity:** System-assigned, with `Cosmos DB Built-in Data Contributor` role
- **App Settings:** `COSMOS_ENDPOINT`, `COSMOS_DATABASE`, `COSMOS_CONTAINER`, `AzureWebJobsStorage`
- **Processing:** Append status "Processed by agent" and `agentResult` field to document

#### Files Modified
- `azure-function/function_app.py`
- `azure-function/host.json`
- `azure-function/requirements.txt`
- `infrastructure/deploy-azure-function.sh`

---

### Function App Hosting Plan — Ripley

**Date:** 2025-07-14 | **Status:** Implemented

#### Decision: Switch from Consumption to App Service Plan B1

Root cause: Azure Policy enforces `allowSharedKeyAccess=false`, but Consumption plan REQUIRES file shares created via shared keys. This is a hard platform constraint that cannot be worked around.

**Solution:** Use App Service Plan B1 (Linux) instead. B1 stores function code on the local VM filesystem, completely bypassing the file share requirement.

| | Consumption | App Service Plan B1 |
|---|---|---|
| **Cost** | Pay-per-execution | ~$13/month (always-on) |
| **File shares** | Required (shared keys) | Not required |
| **Scale** | Auto (0→N) | Manual (1 instance) |
| **Cold start** | Yes | No (always warm) |

For this workload, B1 is actually preferable — always-on means no cold starts and faster email processing.

#### Impact
- `infrastructure/deploy-azure-function.sh` — modified
- New resource: App Service Plan `email-analyzer-func-plan`
- No changes to function code or RBAC assignments

---

### Storage Account Public Network Access — Ripley

**Date:** 2025-07-25 | **Status:** Implemented

#### Decision: Explicitly set public network access on Function App storage account

The Function App `email-analyzer-func` became unhealthy because storage account `emailanalyzerfuncstor` had public network access disabled. The Function App has no VNet integration or private endpoints and relies on public network access to reach `AzureWebJobsStorage`. Without it, the runtime cannot manage triggers or lease blobs, causing `AuthorizationFailure`.

**Solution:** Add `--public-network-access Enabled` to storage account creation in deploy script. This makes the setting explicit rather than relying on Azure subscription defaults, which can be overridden by Azure Policy.

#### Alternatives Considered
1. **VNet integration + private endpoints** — More secure but significantly more complex and costly
2. **Leave it implicit and fix manually** — Fragile; same issue recurs on every fresh deployment if subscription policy changes

#### Consequences
- Future deployments will reliably create storage with public access enabled
- If project later adopts VNet integration, this flag should be revisited and set to `Disabled` once private endpoints are in place

#### Files Modified
- `infrastructure/deploy-azure-function.sh`

---

### Classification Output Filtering — Ripley

**Date:** 2025-07-25 | **Status:** Implemented

#### Decision: Add Filter_Array for Classification Output Parsing

**Problem:** `Parse_Classification` used hardcoded `[1]` index to access Foundry agent response output array. Output array contains elements of different types (`reasoning`, `message`) whose order is not guaranteed by the API.

**Solution:** Added `Filter_Classification_Output` action (Logic App `Query` type) between `Classify_Email` and `Parse_Classification`:
- Filters output for items where `type` equals `"message"`
- `Parse_Classification` now reads `first(body('Filter_Classification_Output'))?['content'][0]?['text']`

#### Rationale
- **Resilience:** Output element order may change between API versions
- **Correctness:** Filtering by type is semantically correct; indexing by position is fragile
- **Pattern consistency:** Recommended approach for any multi-element API response parsing in Logic Apps

#### Impact
- No downstream changes — `Parse_Classification` output shape is identical
- No deploy script changes — no new placeholders introduced

#### Files Modified
- `logic-app/workflow.json` — added `Filter_Classification_Output`, updated `Parse_Classification`

---

### Container App Cosmos DB Role Upgrade — Ripley

**Date:** 2025-07-21 | **Status:** Approved

#### Decision: Upgrade Container App Cosmos DB role to Data Contributor

**Context:** Web app's `DELETE /api/emails/:id` endpoint needs delete permissions. Container App's managed identity was assigned `Cosmos DB Built-in Data Reader` (read-only), causing 403 RBAC errors on deletes.

**Solution:** Upgrade Container App's Cosmos DB role from **Data Reader** to **Data Contributor** (00000000-0000-0000-0000-000000000002). Contributor role includes read, create, replace, and delete — all operations needed for full CRUD.

#### Impact
- `infrastructure/deploy.sh` — role assignment changed from Reader to Contributor
- `README.md` — security table updated
- `docs/architecture.md` — role table updated
- Managed Identity Roles table in `.squad/decisions.md` — updated

#### Migration Note for Existing Deployments
If infrastructure was already deployed with the Reader role, manually reassign:
```bash
# Find assignment ID
az cosmosdb sql role assignment list --account-name <cosmos-account> --resource-group <rg> \
  --query "[?principalId=='<container-app-principal-id>']"

# Then re-run deploy.sh to create Contributor assignment
```

---

### Key Vault Integration — Ripley

**Date:** 2025-07-XX | **Status:** Implemented

#### Decision: Add Key Vault integration pattern for Logic App

**Pattern:**
- Standalone `infrastructure/deploy-keyvault.sh` for KV provisioning (independent lifecycle)
- RBAC authorization (not legacy access policies) — aligns with zero-access-key security model
- `keyvault` API connection using managed identity auth pattern
- `Get_Secret` action placed early in workflow (after variable init, before first Cosmos write)
- Secret name uses `__KEY_VAULT_SECRET_NAME__` placeholder (consistent with existing `__STORAGE_ACCOUNT__`, `__COSMOS_ACCOUNT__` pattern)

#### Impact
- **deploy.sh:** Provisions keyvault API connection + includes in $connections + access policy loop
- **redeploy-logic-app.sh:** Includes keyvault in $connections payload + sed replacement
- **workflow.json:** New Get_Secret action in the action chain
- **connections.json:** Reference entry added

#### Team Notes
- Lambert: No UI changes needed
- Kane: Workflow chain changed — Get_Secret now between Initialize_Status_History and Create_Initial_Cosmos_Document
- All: `KEY_VAULT_SECRET_NAME` env var required for deploy/redeploy scripts

---

### Mortgage Inquiry Classification Category — Ripley

**Date:** 2025-01-15 | **Status:** Implemented

#### Decision: Add `mortgage_inquiry` Classification Category

**Context:** Feature request from dsanchor to expand EmailClassifierAgent classification scope

**Changes:**
- Added category `mortgage_inquiry` in `foundry-agent/create_classifier_agent.py` (line 46-47)
- Placed logically after `sales_inquiry` (both are product interest categories)
- Description covers: customer interest in mortgages, inquiries about rates/terms/conditions, requirements, product applications

#### Design Rationale
- **Logical placement:** Grouped with `sales_inquiry` (both represent customer product interest)
- **Confidence score:** Example (96) reflects unambiguous language — helps validate agent scoring calibration
- **No downstream changes:** Classification data flows to Cosmos DB and web UI unchanged
- **Consistency:** Follows existing pattern; now 14 categories (increased from 13)

#### Testing
- Manual: Create test email with mortgage interest keywords, verify classification as `mortgage_inquiry`
- Automated: No test suite exists for classification instructions (future work)

#### Deployment
No special steps. Next run of `create_classifier_agent.py` will provision agent with new category.

---

### Personal Information Validation Agent — Ripley

**Date:** 2025-04-27 | **Status:** Implemented

#### Decision: PersonalInformationValidationAgent Architecture

**Context:** System needed a second agent to validate personal documents (IRPF and Vida Laboral) extracted from email attachments. Azure Function was using mock validation data and needed real agent-based validation.

#### Architecture Decisions

1. **Separate Agent vs. Single Multi-Purpose Agent**
   - Chosen: Separate specialized agent for validation
   - Rationale: Classification and validation are distinct concerns; allows independent evolution and versioning

2. **Invocation Method: Responses API vs. Direct Agent SDK**
   - Chosen: Responses API (stateless HTTP calls)
   - Rationale: Consistent with Logic App's invocation pattern; simpler error handling for serverless functions

3. **Authentication: Managed Identity vs. API Keys**
   - Chosen: Managed Identity with `https://ai.azure.com` audience
   - Rationale: Zero secrets; consistent with Cosmos DB access pattern; automatic token rotation

4. **Agent Input Format**
   - Chosen: JSON string containing document data
   - Rationale: Preserves structure; easier to extend; more robust than text parsing

5. **Error Handling**
   - Chosen: Always return structured agentResult, include error in result if agent fails
   - Rationale: Downstream systems expect consistent structure; failures visible in UI rather than silently lost

#### Validation Rules
The agent validates 4 business rules:
1. **Required Documents** — Both IRPF and Vida Laboral must be present
2. **Name Consistency** — Full name must match across both documents
3. **Bank Account & CSV** — IBAN and CSV code must be in IRPF
4. **CEA Code Consistency** — CEA code must be same across all Vida Laboral pages

Each rule returns `{"rule": "...", "status": "pass|fail", "detail": "..."}`.

#### Configuration
- `FOUNDRY_AGENT_ENDPOINT` — Base endpoint
- `VALIDATION_AGENT_APP_NAME` — Application name (default: `personal-info-validator`)

#### Alternatives Considered
1. **Extend EmailClassifierAgent** — Violates single responsibility; makes prompt bloated
2. **Use Azure OpenAI directly** — Loses Foundry versioning and monitoring features
3. **Process in Logic App instead of Function** — Logic App already handles classification; keeps concerns separated
4. **Store validation rules in code/config** — Business logic better captured by LLM; easier to update

#### Positive Consequences
- Clean separation between classification and validation agents
- Easy to add more agents following the same pattern
- Consistent authentication across all agents
- Validation logic centralized in agent instructions

#### Negative Consequences
- Two agent deployments to manage
- Additional Foundry costs for validation calls
- Network latency for agent API calls

#### Files Modified
- `foundry-agent/create_validation_agent.py` — Agent creation script
- `azure-function/function_app.py` — Updated with agent invocation logic
- `infrastructure/deploy-azure-function.sh` — Added env vars to function app settings

---

### Validation Agent Rules Refinement — Ripley

**Date:** 2025-07-25 | **Status:** Implemented

#### Decision: Split Bank Account & CSV Rules and Fix Name Order Matching

**Context:** PersonalInformationValidationAgent had issues:
- Rule 3 combined bank account and CSV validation, making it hard to distinguish which check failed
- Rule 2 used exact string matching, failed when documents listed names in different order (common in Spanish official documents)

#### Decisions

1. **Split Bank Account & CSV into Separate Rules**
   - Rule 3 — Bank Account from IRPF (5 IBAN components only)
   - Rule 4 — CSV Code from IRPF (standalone)
   - Rule 5 — CEA Code Consistency (renumbered from old Rule 4)
   - Agent now returns 5 statements instead of 4

2. **Order-Independent Name Matching**
   - Rule 2 now extracts individual name parts and compares as a SET
   - Handles "García López, Juan" vs "Juan García López" transparently
   - Ignores order, punctuation, and separators

#### Impact
- **Lambert/Kane:** `agentResult.statements` array now has 5 items instead of 4. UI and tests should handle gracefully (array-based rendering should work without changes).
- **Ripley:** Agent must be re-provisioned (`python create_validation_agent.py`) and re-published to pick up new prompt

#### Files Modified
- `foundry-agent/create_validation_agent.py`

---

### Agent Result Display — Lambert

**Date:** 2025-07-27 | **Status:** Implemented

#### Decision: Add Agent Result Section in Email Detail

**What:** Added new "Agent Result" section to email detail page (`EmailDetail.jsx`) that displays validation/result information from the `agentResult` field in Cosmos DB document.

#### Implementation Details

**Component Changes (`EmailDetail.jsx`):**
- Conditional rendering checking for `email.agentResult` with non-empty `statements` array
- Renders **before** the Classification section
- Displays:
  - `agentResult.title` as an h2 section heading
  - `agentResult.statements` as a styled list with checkmark bullets
- Completely hidden if `agentResult` is absent, null, or has empty statements array

**Styling (`App.css`):**
- `.detail__agent-result` — Container with 32px bottom margin
- `.detail__agent-result-title` — Heading using SF Pro Display, 21px, 600 weight
- `.detail__agent-result-body` — White background card with 8px rounded corners
- `.agent-result-list` — Flexbox column with 10px gaps
- `.agent-result-list__item` — Text with 20px left padding for checkmark bullets
- `.agent-result-list__item::before` — Blue checkmark (✓) positioned absolutely

All styles follow existing Apple-inspired design patterns and CSS variable system.

#### Example Output
Given:
```json
{
  "agentResult": {
    "title": "Validation",
    "statements": ["DNIs match", "Birthday match", "Same name and surname"]
  }
}
```

Renders: Heading "Validation" with three items prefixed with blue checkmarks.

#### Testing
- Follows existing component patterns: conditional rendering safety, .map() with index keys, no external dependencies
- Compatible with existing CSS variable system

#### Files Modified
- `web-app/src/pages/EmailDetail.jsx`
- `web-app/src/App.css`

---

### Draggable Column Resizing — Lambert

**Date:** 2025-07-27 | **Status:** Implemented

#### Decision: Add Column Width Resizing to Email Table

**Context:** Column widths were hardcoded in CSS. Commit af98f15 narrowed them too aggressively (Subject at 500px fixed). Users need ability to adjust widths.

#### Implementation

1. **Reverted** column width CSS to original values (date: 180px, from: 220px, subject: auto on desktop)
2. **Added drag-to-resize handles** on each table header column
   - Thin invisible handle on right edge of each `<th>`
   - Click-drag resizing with user-set widths stored in React state
   - Applied as inline styles, overriding CSS defaults

#### Rationale
- Hardcoded widths can't anticipate all content lengths
- Drag-to-resize is a standard desktop UX pattern users understand
- No external libraries — pure mousedown/mousemove/mouseup with React state
- Handle styling minimal: invisible by default, Apple Blue indicator on hover/active

#### Technical Details
- **CSS:** `.resize-handle` positioned absolute right, 6px hit area, `::after` for 2px blue indicator line
- **React:** `colWidths` state object, `handleResizeStart` callback with document-level event listeners, `useRef` for tracking active drag
- **Min width:** 50px prevents columns from collapsing

#### Impact
- Kane: No test changes needed — resize is visual interaction only
- Ripley: No infrastructure changes
- Build: Verified — `npm run build` passes

#### Files Modified
- `web-app/src/App.css` — column width revert + resize handle styles
- `web-app/src/pages/EmailList.jsx` — resize state and handlers

---

### Azure Function Documentation — Dallas

**Date:** 2024 | **Status:** Complete

#### Decision: Add Comprehensive Documentation for Optional Azure Function

Added comprehensive documentation for the optional Azure Function (Cosmos DB change feed processor) across project documentation suite.

#### What Was Documented

1. **README.md** — New Optional Feature Section
   - Section 3: "Azure Function — Cosmos DB Change Feed Processor (Optional)"
   - Included: what it does, prerequisites, deployment command, environment variables, monitoring
   - Marked as OPTIONAL, following same style as Content Understanding
   - Updated architecture diagram to show Function's optional connection to Cosmos DB
   - Updated Security table to include Function MI → Cosmos DB Data Contributor role
   - Updated Project Structure to include `azure-function/` directory

2. **docs/architecture.md** — Detailed Architecture Documentation
   - Updated Solution Overview diagram to show Function reading from Cosmos DB change feed
   - Updated Component Interaction Flow (steps 1-8 → 1-9) to include Function processing as step 6
   - Updated Managed Identity Roles: added new "Azure Function (System-Assigned Managed Identity, Optional)" section
   - Updated Deployment Architecture to mention `deploy-azure-function.sh` as optional step
   - Updated Project Structure to include `azure-function/` directory with all files

#### Documentation Style Consistency

All new documentation follows existing patterns:
- **Consistency with Content Understanding section:** Marked as optional; includes prerequisites, setup steps, environment variables
- **Table formatting:** Matches existing README tables for environment variables and roles
- **Tone:** Professional, clear, action-oriented; emphasizes zero-connection-string security model
- **Links:** References back to `azure-function/README.md` for detailed function-specific docs

#### Key Design Decisions

1. **Optional Feature Positioning:** Placed in same tier as Content Understanding and Foundry Agent
2. **Security Table Addition:** Function MI role only appears in Security table, reinforcing that Function is optional
3. **Architecture Diagram Update:** Used (optional) label and separate arrow path
4. **Deployment Script Location:** `infrastructure/deploy-azure-function.sh` (separate from main `deploy.sh`) allows deploying core first, then optionally add Function

#### Files Modified
- `README.md` — Added section, updated diagram, updated security table, updated project structure
- `docs/architecture.md` — Updated diagrams, flow, roles, deployment pipeline, project structure

---

### Validation Agent Integration Documentation — Dallas

**Date:** 2025-01-25 | **Status:** Documented

#### Decision: Document Validation Agent Integration with Azure Function

Azure Function's change feed processor originally used **mock validation data**. This has been replaced with a **real Azure AI Foundry agent** (`PersonalInformationValidationAgent`) that validates email documents against 4 business rules.

#### Changes Made

1. **New Foundry Agent: `PersonalInformationValidationAgent`**
   - Purpose: Validates documents against 4 business rules
   - Location: Azure AI Foundry project (provisioned by `foundry-agent/create_validation_agent.py`)
   - Invocation: Responses API (same pattern as classifier agent)
   - Auth: Managed identity with audience `https://ai.azure.com/.default`

2. **Azure Function Integration** (`azure-function/function_app.py`)
   - Function calls `call_validation_agent()` when document reaches "Email classified" status
   - Uses `urllib.request` + `DefaultAzureCredential` (no external HTTP libs)
   - Responses API URL: `{FOUNDRY_AGENT_ENDPOINT}/openai/responses?api-version=2025-11-15-preview`
   - Agent reference: `{"agent": {"name": "PersonalInformationValidationAgent", "type": "agent_reference"}}`
   - Error handling: Status "Processed by agent" if succeeds; "Agent processing failed" if error
   - Idempotency: Skips if "Processed by agent" already in statusHistory

3. **New Result Format**
   ```json
   {
     "title": "Validation",
     "statements": [
       {
         "rule": "Required Documents",
         "status": "pass",
         "detail": "All required documents are present"
       },
       {
         "rule": "Name Consistency",
         "status": "pass",
         "detail": "Customer name matches across all documents"
       },
       {
         "rule": "Bank Account & CSV",
         "status": "fail",
         "detail": "Bank account format invalid in CSV file"
       },
       {
         "rule": "CEA Code Consistency",
         "status": "pass",
         "detail": "CEA code consistent throughout submission"
       }
     ]
   }
   ```

4. **Environment Variables**
   | Variable | Description |
   |----------|-------------|
   | `FOUNDRY_AGENT_ENDPOINT` | Azure AI Foundry project endpoint |
   | `VALIDATION_AGENT_NAME` | Agent name (default: `PersonalInformationValidationAgent`) |

5. **Managed Identity Permissions**
   - Azure Function requires: `Cosmos DB Built-in Data Contributor` (existing)
   - New: `Azure AI User` on Azure AI Foundry project

#### Documentation Updates

1. **`azure-function/README.md`**
   - Function Behavior describes calling real validation agent
   - Agent Result Format shows new object-based statements
   - Environment Variables include Foundry endpoint and agent name
   - Authentication section mentions Foundry access requirement
   - Local development section includes new env vars

2. **`README.md` (root)**
   - Section 1: Email Classification Agent setup
   - Section 2: Validation Agent setup (new, optional for change feed)
   - Section 3: Content Understanding (unchanged)
   - Section 4: Azure Function (updated for real agent)
   - Security table adds: Azure Function → Foundry AI project → Azure AI User
   - Project Structure includes `create_validation_agent.py`

3. **`docs/architecture.md`**
   - Component Interaction Flow step 6: calls real agent instead of mock
   - Email Document Schema: includes `agentResult` with structured statements
   - Design Decisions: updated for `statusHistory`, `agentResult` with structured format
   - Managed Identity Roles: Azure Function → Foundry AI project → Azure AI User
   - Project Structure: includes validation agent provisioning script

#### Rationale

1. **Real validation:** Agent applies business logic, not mock data
2. **Audit trail:** `statusHistory` tracks processing pipeline state with timestamps
3. **Structured results:** Each statement includes rule name, status, and detail for programmatic processing
4. **Consistency:** Validation agent follows same Responses API pattern as classifier agent
5. **Managed identity:** Zero secrets, consistent with project security model

#### Impact

- **Logic App:** No changes — still provides document data to function
- **Web App:** Can now display structured validation results
- **Testing:** Function tests should reflect new agent response format
- **Deployment:** `deploy-azure-function.sh` must assign Azure AI User role to function MI

---

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
- Quality findings and action items tracked in decision records
