# Email Analyzer — Architecture

## Solution Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Azure Resource Group                             │
│                                                                         │
│  ┌──────────────┐       ┌──────────────┐       ┌──────────────────────┐ │
│  │              │       │              │──────▶│                      │ │
│  │   Microsoft  │──────▶│  Logic App   │ upload│  Azure Blob Storage  │ │
│  │   365 Email  │ trigger│ (Consumption)│       │  email-attachments/  │ │
│  │              │       │              │       │  {emailId}/{filename}│ │
│  └──────────────┘       └──┬──┬───┬───┘       └──────────┬───────────┘ │
│                            │  │   │ analyze PDFs         │ read       │
│                      store │  │   ▼                      │            │
│                            │  │ ┌──────────────────┐     │            │
│                            │  │ │  Content          │     │            │
│                            │  │ │  Understanding    │     │            │
│                            │  │ │  (AI Services)    │     │            │
│                            │  │ └──────────────────┘     │            │
│                            │  │ classify                 │            │
│                            │  ▼                          │            │
│                            │ ┌──────────────────┐        │            │
│                            │ │  Foundry Agent    │        │            │
│                            │ │  (AI Foundry)     │        │            │
│                            │ └──────────────────┘        │            │
│                            ▼                             │            │
│                         ┌──────────────┐                  │            │
│                         │              │                  │            │
│                         │  Cosmos DB   │◀─────┐          │            │
│                         │  (NoSQL API) │ feed │          │            │
│                         │  serverless  │      │          │            │
│                         └──────┬───────┘      │          │            │
│                                │ query       │ (opt)    │            │
│                                │             │          │            │
│                    ┌───────────────────────────┼──────┐  │            │
│                    │                           │      │  │            │
│                    ▼                           ▼      ▼  ▼            │
│         ┌────────────────────────────────────────┐   ┌──────────┐    │
│         │                                        │   │  Azure   │    │
│         │     Azure Container Apps               │   │ Function │    │
│         │     (Web App — Node.js/React)          │   │(Processor)   │
│         │                                        │   └──────────┘    │
│         └────────────────────────────────────────┘                   │
│                                 │                                     │
│                                 ▼                                     │
│                            End Users                                  │
│                           (Browser)                                   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Interaction Flow

```
1. New email arrives ──▶ Office 365 connector triggers Logic App
2. Logic App extracts email metadata (subject, from, body, etc.)
3. Logic App iterates over each attachment:
   a. Gets attachment content from Office 365
   b. Uploads to Blob Storage at: email-attachments/{emailId}/{filename}
   c. If PDF: calls Content Understanding API for field extraction
   d. Appends attachment metadata (+ analysis result if PDF) to array
4. Logic App calls Foundry Agent (Response API) with subject + body for classification
   - Returns: {"type": "...", "score": N, "reasoning": "..."}
5. Logic App upserts email document with attachments + classification to Cosmos DB
6. [OPTIONAL] Azure Function is triggered by Cosmos DB change feed:
   a. Detects document with statusHistory ending in "Email classified"
   b. Calls PersonalInformationValidationAgent via Foundry Responses API
   c. Appends "Processed by agent" status entry (or "Agent processing failed" on error)
   d. Adds agentResult with structured validation statements (rule, status, detail)
   e. Updates document in Cosmos DB
7. Web App queries Cosmos DB for email list / detail
8. Web App streams attachments from Blob Storage via managed identity
9. Web App renders classification (type badge, score, reasoning), CU results, and agent validation status
```

---

## Cosmos DB Schema

**Database:** `email-analyzer-db`
**Container:** `emails`
**Partition Key:** `/messageId`

### Email Document

```json
{
  "id": "<unique-guid>",
  "messageId": "<office365-message-id>",
  "subject": "Quarterly Report Q4 2024",
  "body": "<full HTML body>",
  "bodyPreview": "Hi team, please find the quarterly report attached...",
  "from": {
    "name": "Jane Smith",
    "address": "jane.smith@contoso.com"
  },
  "toRecipients": [
    {
      "name": "David Sancho",
      "address": "dsanchor@microsoft.com"
    }
  ],
  "receivedDateTime": "2024-12-15T14:30:00Z",
  "hasAttachments": true,
  "isRead": true,
  "importance": "normal",
  "conversationId": "<office365-conversation-id>",
  "attachments": [
    {
      "name": "Q4-Report.pdf",
      "contentType": "application/pdf",
      "size": 245760,
      "blobPath": "email-attachments/abc123/Q4-Report.pdf",
      "contentUnderstanding": {
        "status": "Succeeded",
        "result": {
          "analyzerId": "invoiceAnalyzer",
          "apiVersion": "2025-11-01",
          "contents": [
            {
              "category": "Invoice",
              "analyzerId": "invoiceAnalyzer",
              "fields": {
                "InvoiceNumber": { "type": "string", "valueString": "INV-2024-001", "confidence": 0.98 },
                "Total": { "type": "number", "valueNumber": 12500.00, "confidence": 0.95 }
              }
            }
          ]
        }
      }
    },
    {
      "name": "Budget.xlsx",
      "contentType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "size": 102400,
      "blobPath": "email-attachments/abc123/Budget.xlsx"
    }
  ],
  "classification": {
    "type": "policy management",
    "score": 90,
    "reasoning": "The email discusses policy terms and renewal options..."
  },
  "agentResult": {
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
  },
  "statusHistory": [
    {
      "status": "Email received",
      "timestamp": "2024-12-15T14:30:00Z"
    },
    {
      "status": "Email classified",
      "timestamp": "2024-12-15T14:30:03Z"
    },
    {
      "status": "Processed by agent",
      "timestamp": "2024-12-15T14:30:05Z"
    }
  ],
  "processedAt": "2024-12-15T14:30:05Z",
  "_ts": 1702650605
}
```

### Design Decisions

| Decision | Rationale |
|----------|-----------|
| Partition key: `/messageId` | Each email is a unique conversation anchor; queries are per-email |
| Serverless capacity mode | Cost-efficient for bursty email workloads — pay per request |
| Attachments embedded in document | Avoids cross-document joins; single read returns full email context |
| `contentUnderstanding` per attachment | CU results stored alongside attachment metadata; no separate lookup needed |
| `classification` at document level | Email classification applies to the whole email, not individual attachments |
| `bodyPreview` separate from `body` | Enables fast list views without loading full HTML bodies |
| `statusHistory` array | Tracks email processing pipeline state with timestamps for audit trail |
| `agentResult` with structured statements | Validation results include rule name, pass/fail status, and detail message |
| `processedAt` timestamp | Tracks when Logic App processed the email vs. when it was received |

---

## Blob Storage Structure

**Storage Account:** Standard_LRS (locally redundant)
**Container:** `email-attachments`

```
email-attachments/
├── <emailId-1>/
│   ├── Q4-Report.pdf
│   └── Budget.xlsx
├── <emailId-2>/
│   └── presentation.pptx
└── <emailId-3>/
    ├── photo.jpg
    ├── notes.docx
    └── data.csv
```

**Path Convention:** `email-attachments/{emailId}/{original-filename}`

- `emailId` is the Cosmos DB document `id` (GUID), ensuring uniqueness
- Original filename is preserved for user-friendly downloads
- All file types are accepted — no filtering by content type

---

## Logic App Workflow Design

**Type:** Logic App (Consumption)
**Workflow:** Triggered on email arrival, processes per-message via splitOn
**Location:** Azure serverless (no App Service Plan needed)

### Workflow Steps

```
┌─────────────────────────────────────┐
│ Trigger: When a new email arrives   │
│ (Office 365 Outlook connector)      │
│ Folder: Inbox                       │
│ Include Attachments: Yes            │
│ Subject filter: "Demo email"        │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Initialize Attachments Array        │
│ (empty array variable)              │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ For Each: attachment                │
│  ├─ Get Attachment (O365 V2)       │
│  ├─ Create Blob in Storage          │
│  │  Container: email-attachments    │
│  │  Path: {emailId}/{filename}      │
│  │  Content: attachment bytes       │
│  ├─ Check If PDF                    │
│  │  ┌─ True (PDF) ───────────────┐  │
│  │  │ Call Content Understanding  │  │
│  │  │ API (HTTP + MI auth)       │  │
│  │  │ Append attachment with     │  │
│  │  │ contentUnderstanding result │  │
│  │  └────────────────────────────┘  │
│  │  ┌─ False (non-PDF) ──────────┐  │
│  │  │ Append attachment without   │  │
│  │  │ analysis data              │  │
│  │  └────────────────────────────┘  │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Classify Email (HTTP POST)          │
│ Foundry Agent Response API          │
│ Input: subject + body               │
│ Auth: MI (cognitiveservices.azure.com)│
│ Output: type, score, reasoning      │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Parse Classification (Compose)      │
│ Extract JSON from response          │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Upsert Document (Cosmos DB)         │
│ Write email metadata + attachments  │
│ + classification to Cosmos DB       │
└─────────────────────────────────────┘
```

### Content Understanding Integration

For each PDF attachment, the Logic App calls the Content Understanding REST API:

- **Endpoint:** `{CU_ENDPOINT}/contentunderstanding/analyzers/{ANALYZER_ID}:analyze?api-version=2025-11-01`
- **Method:** POST with base64-encoded PDF content
- **Auth:** Managed Identity (`audience: https://cognitiveservices.azure.com/`)
- **Response:** Full analysis JSON stored in `contentUnderstanding` field of the attachment

> **Note:** The Content Understanding endpoint and analyzers/classifiers are provided by the user. This is an integration only — the CU resource is independently managed.
```

### Connector Authentication

| Connector | Auth Method |
|-----------|-------------|
| Office 365 Outlook | OAuth2 interactive consent (user's mailbox) |
| Azure Cosmos DB | Managed Identity (System-Assigned) |
| Azure Blob Storage | Managed Identity (System-Assigned) |
| Content Understanding (HTTP) | Managed Identity (audience: `https://cognitiveservices.azure.com/`) |
| Foundry Agent (HTTP) | Managed Identity (audience: `https://cognitiveservices.azure.com/`) |

---

## Managed Identity Roles

All service-to-service communication uses Azure Managed Identities. **Zero connection strings** in the solution.

### Logic App (System-Assigned Managed Identity)

| Target Resource | Role | Purpose |
|----------------|------|---------|
| Storage Account | **Storage Blob Data Contributor** | Upload attachment blobs |
| Cosmos DB Account | **Cosmos DB Built-in Data Contributor** | Create and update email documents |
| Content Understanding (AI Services) | **Cognitive Services User** | Call CU analyzers for PDF field extraction |
| Azure AI Foundry project | **Azure AI User** | Call Foundry Response API for email classification |

### Container App (System-Assigned Managed Identity)

| Target Resource | Role | Purpose |
|----------------|------|---------|
| Storage Account | **Storage Blob Data Reader** | Read/download attachment blobs |
| Cosmos DB Account | **Cosmos DB Built-in Data Contributor** | Query, create, and delete email documents |

### Azure Function (System-Assigned Managed Identity, Optional)

| Target Resource | Role | Purpose |
|----------------|------|---------|
| Cosmos DB Account | **Cosmos DB Built-in Data Contributor** | Read change feed and update email documents with processing status |
| Azure AI Foundry project | **Azure AI User** | Invoke PersonalInformationValidationAgent via Responses API |

### Role Assignment Reference

| Role Name | Role Definition ID |
|-----------|--------------------|
| Storage Blob Data Contributor | `ba92f5b4-2d11-453d-a403-e96b0029c9fe` |
| Storage Blob Data Reader | `2a2b9908-6ea1-4ae2-8e65-a410df84e7d1` |
| Cosmos DB Built-in Data Contributor | `00000000-0000-0000-0000-000000000002` |
| Cosmos DB Built-in Data Reader | `00000000-0000-0000-0000-000000000001` |
| Cognitive Services User | `a97b65f3-24c7-4388-baec-2e87135dc908` |
| Azure AI User | `53ca6127-db72-4e55-ad43-a0e57ead88cb` |

> **Note:** Cosmos DB built-in roles use data-plane RBAC and require `az cosmosdb sql role assignment create`, not the standard `az role assignment create`.

---

## Web Application Architecture

**Runtime:** Node.js 20 + Express (API) + React 19 + Vite (SPA)
**Deployment:** Azure Container Apps (with system-assigned managed identity)
**Container Registry:** GitHub Packages (ghcr.io)

### Routes

| Route | Type | Description |
|-------|------|-------------|
| `GET /` | Redirect | Redirects to `/emails` |
| `GET /emails` | React Page | Sortable, searchable email list table |
| `GET /emails/:id` | React Page | Full email detail with body, attachments, and CU results |
| `GET /api/emails` | JSON API | List all emails (optional `?q=` search filter) |
| `GET /api/emails/:id` | JSON API | Single email detail |
| `GET /api/emails/:id/attachments/:filename` | Stream | Download attachment from Blob Storage |
| `GET /health` | JSON API | Health check endpoint |

### Key Components

| Component | Purpose |
|-----------|---------|
| `server.js` | Express API server — Cosmos DB queries, Blob Storage streaming, HTML sanitization |
| `App.jsx` | React Router — SPA routing and layout |
| `EmailList.jsx` | Email list with sorting, filtering, date formatting |
| `EmailDetail.jsx` | Email detail with body rendering, attachment list, CU viewer integration |
| `ContentUnderstandingViewer.jsx` | Collapsible segment viewer for CU analysis results with structured field tables and raw JSON toggle |
| `Layout.jsx` | Shared page layout wrapper |

### SDK Usage

- **Cosmos DB:** `@azure/cosmos` SDK with `DefaultAzureCredential`
- **Blob Storage:** `@azure/storage-blob` SDK with `DefaultAzureCredential`
- **Auth:** `@azure/identity` for managed identity
- **Sanitization:** `sanitize-html` (server-side) + `DOMPurify` (client-side, defense-in-depth)

### Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `COSMOS_ENDPOINT` | Cosmos DB account endpoint | `https://ep-cosmos-xxx.documents.azure.com:443/` |
| `COSMOS_DATABASE` | Database name | `email-analyzer-db` |
| `COSMOS_CONTAINER` | Container name | `emails` |
| `STORAGE_ACCOUNT_URL` | Blob Storage endpoint | `https://epstorxxx.blob.core.windows.net` |
| `STORAGE_CONTAINER` | Blob container name | `email-attachments` |

---

## Security Model

```
┌──────────────────────────────────────────────┐
│              Security Principles              │
├──────────────────────────────────────────────┤
│ ✓ Storage shared key access DISABLED          │
│ ✓ All Azure service auth via Managed Identity│
│ ✓ Zero connection strings in config/code     │
│ ✓ Cosmos DB data-plane RBAC (not keys)       │
│ ✓ Blob Storage data-plane RBAC (not keys)    │
│ ✓ Container images from GitHub Packages      │
│ ✓ HTTPS everywhere                           │
│ ✓ O365 connector: OAuth2 user consent only   │
│ ✗ No shared access signatures (SAS)          │
│ ✗ No storage account keys                    │
│ ✗ No Cosmos DB master keys                   │
└──────────────────────────────────────────────┘
```

---

## Deployment Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Deployment Pipeline                           │
│                                                                  │
│  infrastructure/deploy.sh                                        │
│  ├── Resource Group                                              │
│  ├── Cosmos DB Account (serverless) + Database + Container       │
│  ├── Storage Account (shared keys disabled) + Blob Container     │
│  ├── API Connections (Office 365, Blob, Cosmos DB)               │
│  ├── Logic App (Consumption) + Managed Identity                  │
│  ├── Container Apps Environment + Container App                  │
│  └── Managed Identity Role Assignments (4 assignments)           │
│                                                                  │
│  .github/workflows/build-push.yml                                │
│  ├── Triggered on push to main (web-app/ changes)               │
│  ├── Build Docker image from web-app/Dockerfile                 │
│  └── Push to ghcr.io/<owner>/<repo>/email-analyzer-web            │
│                                                                  │
│  infrastructure/deploy-azure-function.sh (OPTIONAL)             │
│  ├── Function App (Linux, Python 3.11, Consumption)             │
│  ├── Dedicated Storage Account (function runtime internals)      │
│  ├── Lease Container in Cosmos DB (change feed tracking)         │
│  └── Managed Identity Role Assignment (Cosmos DB access)         │
│                                                                  │
│  Post-deploy (manual):                                           │
│  ├── Configure O365 connector (interactive OAuth consent)        │
│  └── Update Container App with ghcr.io image                    │
│  └── [OPTIONAL] Run deploy-azure-function.sh for change feed processing
└─────────────────────────────────────────────────────────────────┘
```

---

## Project Structure

```
email-analyzer/
├── README.md                    # Project overview and setup guide
├── DESIGN.md                    # Apple-inspired design system
├── docs/
│   └── architecture.md          # This document
├── foundry-agent/
│   ├── create_classifier_agent.py  # Provisions the Foundry classification agent
│   ├── create_validation_agent.py  # Provisions the Foundry validation agent (optional)
│   ├── invoke_agent.py          # Tests agents via the Responses API
│   ├── publish_agent.sh         # Publishes agents as Agent Applications (optional)
│   └── requirements.txt         # Python dependencies
├── azure-function/              # Optional: Cosmos DB change feed processor
│   ├── README.md                # Function-specific documentation
│   ├── function_app.py          # Python Azure Function entry point
│   ├── host.json                # Function runtime configuration
│   └── requirements.txt         # Python dependencies
├── infrastructure/
│   ├── deploy.sh                # AZ CLI deployment (all resources)
│   ├── deploy-azure-function.sh # Deploy optional Azure Function
│   ├── redeploy-logic-app.sh    # Redeploy only the Logic App workflow
│   └── enable-public-access.sh  # Enable public access on storage (if needed)
├── logic-app/
│   ├── workflow.json            # Logic App Consumption workflow definition
│   └── connections.json         # Connection reference (documentation only)
├── web-app/
│   ├── server.js                # Express API server
│   ├── package.json             # Node.js dependencies
│   ├── vite.config.js           # Vite build configuration
│   ├── index.html               # Vite entry point
│   ├── Dockerfile               # Multi-stage container image build
│   ├── .dockerignore            # Docker build exclusions
│   └── src/
│       ├── main.jsx             # React entry point
│       ├── App.jsx              # React Router + layout
│       ├── App.css              # Apple-inspired stylesheet
│       ├── pages/
│       │   ├── EmailList.jsx    # Email list view
│       │   ├── EmailDetail.jsx  # Single email detail view
│       │   └── ErrorPage.jsx    # Error boundary page
│       └── components/
│           ├── Layout.jsx       # Shared layout wrapper
│           └── ContentUnderstandingViewer.jsx  # CU analysis results viewer
└── tests/
    ├── app.test.js              # Web app route tests (Jest + Supertest)
    ├── edgeCases.test.js        # Edge case tests
    ├── setup.js                 # Test setup (env vars)
    ├── jest.config.js           # Jest configuration
    └── fixtures/
        ├── sampleEmails.js      # Sample email data
        └── mockAzure.js         # Azure SDK mocks
```
