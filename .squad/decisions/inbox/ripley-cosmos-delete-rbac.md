# Decision: Container App Cosmos DB Role Upgraded to Data Contributor

**Date:** 2025-07-21
**Author:** Ripley (Cloud Dev)
**Status:** Approved

## Context

The web app's `DELETE /api/emails/:id` endpoint needs to delete documents from Cosmos DB. The Container App's managed identity was assigned `Cosmos DB Built-in Data Reader` (00000000-0000-0000-0000-000000000001), which only permits read operations. This caused a 403 RBAC error when attempting deletes.

## Decision

Upgraded the Container App's Cosmos DB role from **Data Reader** to **Data Contributor** (00000000-0000-0000-0000-000000000002). The Contributor role includes read, create, replace, and delete — all operations the web app needs for full CRUD.

## Impact

- `infrastructure/deploy.sh` — role assignment changed from Reader to Contributor
- `README.md` — security table updated
- `docs/architecture.md` — role table updated
- `.squad/decisions.md` — managed identity roles table updated

## Note for Existing Deployments

If the infrastructure was already deployed with the Reader role, you must manually reassign. The old Reader assignment should be removed to follow least-privilege:

```bash
# Remove old Reader assignment (get the assignment ID first)
az cosmosdb sql role assignment list --account-name <cosmos-account> --resource-group <rg> --query "[?principalId=='<container-app-principal-id>']"

# Then delete by assignment ID and re-run deploy.sh to create the Contributor assignment
```
