# Decision: Foundry Agent Publish Script

**Date:** 2025-07-24 | **Author:** Ripley | **Status:** Implemented

## Context

The `create_classifier_agent.py` script provisions the EmailClassifierAgent in Foundry, but there was no tooling to *publish* it as an Agent Application with a managed deployment. Publishing is required to expose the agent via the Responses protocol endpoint that the Logic App calls.

## Decision

Created `foundry-agent/publish_agent.sh` — a bash script that uses ARM REST API (PUT) calls to:
1. Create the Agent Application resource
2. Create a Managed Deployment with Responses protocol
3. Verify deployment reaches `Succeeded` state
4. Optionally grant Azure AI User role for invocation

## Key Details

- **Two different tokens/audiences:**
  - ARM operations (create/deploy): `https://management.azure.com`
  - Agent invocation (Responses API): `https://ai.azure.com`
- **Endpoint pattern:** `https://{account}.services.ai.azure.com/api/projects/{project}/applications/{app}/protocols/openai/responses`
- **API version:** `2025-05-15-preview` for ARM; `2025-11-15-preview` for invocation

## Impact

- **Lambert:** No changes needed — Logic App already calls the Responses endpoint
- **Kane:** No test impact — infrastructure script
- **Pipeline:** Completes the Foundry agent lifecycle: create → publish → invoke
