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
| Container App | Cosmos DB | Cosmos DB Built-in Data Reader | 00000000-0000-0000-0000-000000000001 |
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

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
- Quality findings and action items tracked in decision records
