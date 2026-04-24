## Learnings

- **Project:** email-parser — Azure Logic App email processing pipeline
- **Stack:** Python, Azure (Logic Apps, Cosmos DB, Blob Storage, Container Apps), managed identities
- **Design:** Apple-inspired (DESIGN.md)
- **User:** dsanchor
- **Reference:** https://github.com/glory-ub/PDF-Extraction-from-Mail-using-Logic-App
- **Architecture doc:** `docs/architecture.md` — full system design, Cosmos DB schema, managed identity roles
- **Deploy script:** `infrastructure/deploy.sh` — complete AZ CLI deployment with API connections, env vars, and idempotent role assignments
- **Cosmos DB:** NoSQL API, serverless, database `email-parser-db`, container `emails`, partition key `/messageId`
- **Blob path convention:** `email-attachments/{emailId}/{original-filename}`
- **Logic App:** Standard (WS1), stateful workflow, system-assigned managed identity
- **Web framework decision:** FastAPI with Jinja2 templates, `DefaultAzureCredential`
- **Container App port:** 8000 (FastAPI/uvicorn default)
- **Security:** Zero connection strings, all managed identity, Cosmos data-plane RBAC
- **Project structure:** All placeholder files exist — logic-app/, web-app/, tests/ are populated
- **Deploy script already included API connections** (office365, azureblob, cosmosdb) with access policies — pre-existing work by team
