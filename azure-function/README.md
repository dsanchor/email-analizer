# Email Analyzer — Azure Function (Cosmos DB Change Feed)

## Overview

This Azure Function is triggered by Cosmos DB change feed events on the `emails` container. It processes emails after they have been classified by the Logic App workflow.

## Function Behavior

1. **Trigger**: Cosmos DB change feed on `emails` container
2. **Processing Logic**:
   - For each document, check the last entry in `statusHistory` array
   - If the last status is NOT `"Email classified"` → skip
   - If the last status IS `"Email classified"` → process:
     - Call the **PersonalInformationValidationAgent** in Azure AI Foundry via the Responses API
     - The agent validates the email against 4 business rules: Required Documents, Name Consistency, Bank Account & CSV, CEA Code Consistency
     - Append new status entry: `{"status": "Processed by agent", "timestamp": "<current UTC ISO>"}` (or `"Agent processing failed"` on error)
     - Add `agentResult` field with structured validation results
     - Write updated document back to Cosmos DB

## Agent Result Format

The validation agent returns structured data with individual rule status objects:

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

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `COSMOS_ENDPOINT` | Cosmos DB account endpoint URL | (required) |
| `COSMOS_DATABASE` | Cosmos DB database name | `email-analyzer-db` |
| `COSMOS_CONTAINER` | Cosmos DB container name | `emails` |
| `COSMOS_CONNECTION__accountEndpoint` | Cosmos DB trigger binding connection (MI auth) | (required) |
| `FOUNDRY_AGENT_ENDPOINT` | Azure AI Foundry project endpoint (full project URL) | (required) |
| `VALIDATION_AGENT_NAME` | Name of the validation agent in Foundry | `PersonalInformationValidationAgent` |

## Authentication

Uses **managed identity** (DefaultAzureCredential) for all Azure service access:
- **Cosmos DB:** DefaultAzureCredential (system-assigned MI on Function App)
- **Foundry AI project:** DefaultAzureCredential with token audience `https://ai.azure.com/.default`

The Function App requires `Azure AI User` role on the Azure AI Foundry project to invoke the validation agent.

## Deployment

Use the provided deployment script:

```bash
cd infrastructure
./deploy-azure-function.sh
```

The script will:
1. Create Azure Function App (Linux, Python 3.11, Consumption plan)
2. Enable system-assigned managed identity
3. Assign Cosmos DB Built-in Data Contributor role to the Function App MI
4. Assign Azure AI User role on the Foundry AI project (if `FOUNDRY_RESOURCE_ID` provided)
5. Configure app settings (Cosmos endpoint, database, container, Foundry endpoint, agent name)
6. Create lease container in Cosmos DB
7. Deploy the function code

## Manual Deployment

If you need to deploy manually:

```bash
# Install Azure Functions Core Tools
# https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local

# Deploy from the azure-function directory
cd azure-function
func azure functionapp publish <function-app-name>
```

## Local Development

For local testing, create `local.settings.json` (not committed to repo):

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "COSMOS_ENDPOINT": "https://<your-cosmos-account>.documents.azure.com:443/",
    "COSMOS_DATABASE": "email-analyzer-db",
    "COSMOS_CONTAINER": "emails",
    "COSMOS_CONNECTION__accountEndpoint": "https://<your-cosmos-account>.documents.azure.com:443/",
    "FOUNDRY_AGENT_ENDPOINT": "https://<your-foundry>.services.ai.azure.com/api/projects/<project-id>",
    "VALIDATION_AGENT_NAME": "PersonalInformationValidationAgent"
  }
}
```

Run locally:

```bash
func start
```

## Monitoring

- View logs in Azure Portal → Function App → Monitor → Logs
- Application Insights is automatically configured if available
- Function logs include document IDs and processing status

## Idempotency

The function checks if a document already has a "Processed by agent" status to avoid duplicate processing if the change feed is replayed.
