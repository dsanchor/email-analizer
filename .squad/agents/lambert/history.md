## Learnings

- **Project:** email-parser — Azure Logic App email processing pipeline
- **Stack:** Python, Azure (Logic Apps, Cosmos DB, Blob Storage, Container Apps), managed identities
- **Design:** Apple-inspired (DESIGN.md)
- **User:** dsanchor

### Web App (v1) — Built 2025-04-20
- **Framework:** FastAPI + Jinja2 templates + uvicorn
- **Key files:** `web-app/app.py`, `web-app/templates/`, `web-app/static/css/style.css`, `web-app/Dockerfile`
- **Auth pattern:** `DefaultAzureCredential` (managed identity in prod), falls back to connection string env vars for local dev (`COSMOS_KEY`, `STORAGE_CONNECTION_STRING`)
- **Config:** All via env vars — `COSMOS_ENDPOINT`, `COSMOS_DATABASE`, `COSMOS_CONTAINER`, `STORAGE_ACCOUNT_URL`, `STORAGE_CONTAINER`
- **Routes:** `GET /` → redirect `/emails`, `GET /emails` (paginated list + search), `GET /emails/{id}` (detail), `GET /emails/{id}/attachments/{filename}` (blob download), `GET /health`
- **Design decisions:** Binary dark/light sections on detail page (dark hero for subject/meta, white for body, light gray for attachments). Card-based inbox list. Search bar with filter-style input. Pagination with pill buttons.
- **Dockerfile:** python:3.12-slim, non-root user, port 8000
- **CSS:** Full DESIGN.md compliance — glass nav, Apple Blue only accent, negative letter-spacing at all sizes, 980px pill radius CTAs, card shadows per spec

### Quality Issues — From Kane Testing (2026-04-20)

**🔴 CRITICAL: XSS Vulnerability in email_detail.html**
- **Location:** `web-app/templates/email_detail.html`
- **Issue:** Template uses `{{ email.body | safe }}` which renders email body HTML unescaped
- **Risk:** Malicious email content from Office 365 could inject JavaScript into rendering
- **Impact:** Session hijacking, credential theft, malware distribution potential
- **Fix:** Sanitize email.body before template rendering using `nh3` or `bleach` library
- **Steps:**
  1. Add sanitizer library to requirements.txt (`nh3>=0.2.0` recommended for performance)
  2. Create sanitize utility: `_sanitize_html(body)` in app.py
  3. Update `/emails/{id}` route to call `_sanitize_html()` on email.body before passing to template
  4. Change template to `{{ email.body }}` (remove | safe filter)
  5. Add test case in tests/test_app.py for XSS attack patterns

**🟡 HIGH: Missing Error Handling in Route Handlers**
- **Location:** `/emails` and `/emails/{id}` routes
- **Issue:** Cosmos DB exceptions not caught — propagate as raw 500 errors
- **Effect:** Users see generic error pages; developers can't distinguish Cosmos failures from app bugs
- **Fix:** Wrap `query_items()` calls in try/except
- **Steps:**
  1. Create error handler middleware in app.py
  2. Catch `azure.cosmos.exceptions.CosmosResourceNotFoundError` for 404 cases
  3. Catch `azure.cosmos.exceptions.CosmosHttpResponseError` for general Cosmos failures
  4. Return appropriate status codes + render error.html with user-friendly messages
  5. Add test cases for query failures

### Visual Upgrade (v2) — 2025-07-18

- **Scope:** All 5 frontend files rewritten for cinematic Apple-inspired look
- **Pattern:** Binary dark/light section rhythm applied throughout:
  - Inbox: dark hero (title + count + search) → light gray list
  - Detail: dark hero (56px subject) → light gray metadata grid → white body → dark attachments
  - Error: dark hero (120px code) → light gray message+actions
- **Inbox hero:** 56px SF Pro Display title, email count subtitle, dark-themed search with magnifying glass SVG
- **Email cards:** Avatar with sender initial, hover lift (`translateY(-2px)` + shadow), subject truncation with ellipsis
- **Detail hero:** Subject at display size (56px), structured metadata grid (From/To/Date/Attachments), 720px max-width body for readability
- **Attachments:** Dark section with card grid, file-type SVG icons (PDF, image, doc, spreadsheet, archive, generic), hover lift
- **Error page:** 120px display code, contextual labels (404/500/503), structured actions with SVGs
- **Nav:** SVG mail envelope icon + text brand, inbox link with inbox SVG icon
- **Footer:** Structured with brand name, vertical separator, attribution
- **Transitions:** `--transition-fast: 0.2s ease`, `--transition-medium: 0.35s ease` on all interactive elements
- **Responsive:** Full DESIGN.md breakpoints (360, 480, 640, 834, 1024px) with progressive scaling
- **Template variable:** Uses `total` (not `total_count`) from app.py context
- **All 30 tests passing after changes**

### Cross-Agent Update from Ripley (2026-04-20)

**⚠️ IMPORTANT: Cosmos DB `from` Field Type Changed**
- **Change:** Ripley fixed Logic App to preserve `from` as native JSON object instead of string
- **Before:** `from` was string (corrupted by string interpolation)
- **After:** `from` is now `{emailAddress: {name: "...", address: "..."}}`
- **Your Action:** Update any template code that accesses `email.from` to use `email.from.emailAddress.address` for email address, `email.from.emailAddress.name` for display name
- **Impact:** Visual Upgrade (v2) assumed `from` was string; may need template adjustments if directly accessing `from` field
- **Test Status:** All 30 tests still passing (verify with `cd web-app && python -m pytest ../tests/ -v`)

---

### UI Refresh & Data Model Fix (v3) — 2025-07-18

- **Scope:** Data model compatibility + UI polish + new dashboard page
- **Data Model Fixes:**
  - Added Jinja2 filters: `extract_from`, `extract_from_display`, `extract_from_initial`, `extract_body`, `extract_recipients`
  - These handle both string and object forms of `from`, `body`, and `toRecipients` fields
  - Fixed `sanitize_html` in `email_detail` route to extract body content from object form before sanitizing
  - Email detail metadata now shows sender name as primary text with email address as secondary
- **New Dashboard Page:**
  - Route: `GET /dashboard` — shows total email count, attachment stats, and 5 most recent emails
  - Template: `dashboard.html` with stat cards and recent email list
  - Dashboard link added to nav bar
- **CSS Polish:**
  - Removed legacy CSS section (search-bar, search-input, search-btn, generic card classes)
  - Added subtle `border-bottom` on glass nav for definition
  - Tightened email card gap from 6px to 2px for cleaner stacking
  - Added `detail-meta__name` and `detail-meta__secondary` styles for structured from display
  - Added full dashboard styles with stat cards, responsive grid
  - Dashboard responsive: 3-col → 1-col stats on mobile
- **All 30 tests passing — no regression**

---

### Cross-Team Update from Ripley (2026-04-20)

**⚠️ INFRASTRUCTURE UPDATE: AccountNameFromSettings Fix**
- **Change:** Ripley fixed Logic App workflow to substitute account name placeholders at deploy time
- **What happened:** Managed API connections (Blob, Cosmos) were failing because `workflow.json` contained literal `AccountNameFromSettings` placeholder instead of actual account names
- **Solution:** Deploy script now uses `sed` to substitute `__STORAGE_ACCOUNT__` and `__COSMOS_ACCOUNT__` tokens before deployment
- **Your Action:** No code changes needed. Dashboard and templates will now receive data correctly from properly-configured Cosmos DB.
- **Impact:** Infrastructure reliability — Blob Storage and Cosmos DB actions now resolve to correct accounts
- **Test Status:** All 30 tests still passing (verify with `cd web-app && python -m pytest ../tests/ -v`)

---

### Complete UI Rewrite (v4) — 2025-07-18

- **Scope:** Full frontend rewrite — from card-based layout to clean sortable table
- **Motivation:** User feedback: previous design was overengineered and visually noisy
- **Changes:**
  - **Inbox:** Single sortable table (Date, From, Subject) with client-side JS column sorting (click headers to toggle asc/desc)
  - **Detail:** Clean flat layout — subject heading, metadata card (From/To/Date), body card, attachment list
  - **Removed:** `/dashboard` route + `dashboard.html` template, pagination, hero sections, avatar circles, card grid layouts
  - **CSS:** Complete rewrite from scratch — ~400 lines down from ~700+. Table-focused, minimal chrome
  - **JS:** `static/js/sort.js` — external file for table sorting (avoids inline `<script>` which tripped XSS tests)
  - **Search:** Live filter input with clear button, submits as query param
- **Design compliance (DESIGN.md):**
  - Glass nav: `rgba(0,0,0,0.8)` + `backdrop-filter: blur(20px)`
  - Background: `#f5f5f7`, text: `#1d1d1f`, accent: Apple Blue `#0071e3` only on interactive elements
  - SF Pro font stack, negative letter-spacing at all sizes
  - Pill-shaped buttons (980px radius)
  - Responsive: horizontal table scroll on mobile, stacked metadata on small screens
- **Data model:** All Jinja2 filters preserved (extract_from, extract_body, etc.) — handles both string and object field forms
- **All 30 tests passing — no regression**

---

### Frontend Polish (v5) — 2026-04-21

- **Scope:** CSS overhaul + branding cleanup for premium look and feel
- **Commit:** 8473f5c — "Lambert: Frontend polish — Inter font, branding cleanup, micro-interactions"
- **Changes:**
  - **Branding removed:** All "Email Parser", "Powered by Azure" text stripped from nav and footer. Nav brand is now just "Inbox". Footer is empty/invisible.
  - **Titles cleaned:** All `<title>` tags no longer say "Email Parser" — just "Inbox", subject lines, or "Error {code}"
  - **Inter font added:** Google Fonts Inter loaded as primary font (SF Pro substitute for non-Apple browsers). Font stack: `Inter, SF Pro Text/Display, Helvetica Neue, Arial, sans-serif`
  - **Search input:** Pill shape with `border-radius: 11px` per DESIGN.md, thicker focus ring, hover state on border, search icon turns blue on focus
  - **Table micro-interactions:** Subtle blue-tinted hover, zebra striping on even rows (`rgba(0,0,0,0.015)` — very subtle), attachment clip icon fades in on hover
  - **Nav glass bar:** Added subtle `box-shadow` beneath for depth definition
  - **Buttons:** Added `translateY(-1px)` lift on hover, active press state
  - **Smooth scroll:** `html { scroll-behavior: smooth }` added
  - **Sort arrows:** Animated with CSS transitions
  - **Attachment rows:** Icon turns blue on hover, download text fades in
  - **Back link:** Gap widens on hover for playful micro-interaction
  - **No borders on cards/containers:** Removed `box-shadow` from detail meta/body cards per DESIGN.md
  - **CSS variables:** Added `--transition-fast: 0.2s ease`, `--transition-medium: 0.35s ease`, `--shadow-card`, `--shadow-subtle`
- **DESIGN.md compliance:** All colors, typography, nav glass, border radii, shadows match spec
- **Files modified:** `base.html`, `emails.html`, `email_detail.html`, `error.html`, `style.css`
- **All 30 tests passing — no regression**
- **Status:** Complete and production-ready

---

### Node.js + React Rewrite (v6) — 2025-07-20

- **Scope:** Complete rewrite from Python/FastAPI/Jinja2 to Node.js/Express + React SPA
- **Motivation:** User requested full stack migration to Node.js + React
- **Backend (`server.js`):**
  - Express.js API server with same 5 routes: `/` redirect, `/health`, `/api/emails`, `/api/emails/:id`, `/api/emails/:id/attachments/:filename`
  - Azure SDKs: `@azure/cosmos`, `@azure/storage-blob`, `@azure/identity`
  - Same env vars: `COSMOS_ENDPOINT`, `COSMOS_DATABASE`, `COSMOS_CONTAINER`, `STORAGE_ACCOUNT_URL`, `STORAGE_CONTAINER`, `COSMOS_KEY`, `STORAGE_CONNECTION_STRING`
  - Server-side HTML sanitization with `sanitize-html` (replaces bleach)
  - Serves React build from `dist/` in production, SPA fallback for client-side routing
  - Port 8000 preserved for Container Apps compatibility
- **Frontend (React + Vite):**
  - SPA with React Router: `EmailList`, `EmailDetail`, `ErrorPage` pages
  - `Layout` component with glass nav bar
  - Client-side sorting (Date, From, Subject) — replaces `sort.js`
  - Search via URL query params, fetches from `/api/emails?q=`
  - DOMPurify for defense-in-depth XSS prevention on `dangerouslySetInnerHTML`
  - Handles both string and object forms of `from`, `body`, `toRecipients` fields
- **CSS (`App.css`):** 1:1 port of `style.css` — all Apple-inspired design preserved:
  - Glass nav, `#f5f5f7` bg, Inter font, negative letter-spacing, pill buttons (980px radius)
  - Responsive breakpoints at 834, 640, 480px
  - Zebra striping, sort arrows, micro-interactions all retained
- **Dockerfile:** Multi-stage — `node:20-alpine` build stage + production stage, non-root user
- **Files deleted:** `app.py`, `requirements.txt`, `templates/`, `static/`, `__pycache__/`, `.pytest_cache/`
- **Files created:** `package.json`, `server.js`, `vite.config.js`, `index.html`, `src/main.jsx`, `src/App.jsx`, `src/App.css`, `src/components/Layout.jsx`, `src/pages/EmailList.jsx`, `src/pages/EmailDetail.jsx`, `src/pages/ErrorPage.jsx`
- **Build verified:** `npm install` + `npm run build` succeed — 46 modules, 267KB JS bundle
- **GitHub Actions:** No changes needed — `build-push.yml` still uses `context: ./web-app`
- **`.gitignore` updated:** Added `node_modules/`, `web-app/dist/`
