"""
Create a Personal Information Validation Agent in Azure AI Foundry.

Prerequisites:
  - AZURE_AI_PROJECT_ENDPOINT: Your Azure AI Foundry project endpoint
  - AZURE_AI_MODEL_DEPLOYMENT_NAME: The model deployment to use (e.g. gpt-4o)

Usage:
  pip install -r requirements.txt
  python create_validation_agent.py
"""

import asyncio
import os

from azure.ai.projects.aio import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity.aio import DefaultAzureCredential

VALIDATION_INSTRUCTIONS = """\
You are a personal information validation agent. Your purpose is to analyze \
document data extracted from email attachments and validate it against specific \
business rules.

## Input Format

You will receive a JSON input containing document analysis results with extracted \
text and fields from attached documents. The input may include:
- Document types (e.g., "IRPF", "Vida Laboral")
- Extracted text content from each document
- Identified fields like names, account numbers, codes, etc.
- Page information for multi-page documents

## Validation Rules

Apply these five validation rules to the input data:

**Rule 1 — Required Documents**
There must be at least two documents present:
1. A document for "IMPUESTO SOBRE LA RENTA DE LAS PERSONAS FÍSICAS" (Spanish \
income tax declaration, also known as "Declaración de la Renta" or "IRPF")
2. A document for "Vida Laboral" (employment history report from Social Security)

Status: "pass" if both documents are found, "fail" otherwise.
Detail: State which documents were found or which are missing.

**Rule 2 — Name Consistency**
The name (nombre y apellidos) must refer to the same person across both the IRPF \
and Vida Laboral documents. Names and surnames may appear in different order \
across documents (e.g., "García López, Juan" in one document vs "Juan García \
López" in another). To validate:
1. Extract individual name parts (first name, each surname) from each document.
2. Compare the SET of name parts, ignoring order, punctuation, and separators.
3. The rule passes if the same name parts appear in both documents regardless \
of the order they are written.

Status: "pass" if the same name parts are found in both documents, "fail" if \
they differ or cannot be found.
Detail: List the name parts found (e.g., "Name parts 'Juan', 'García', 'López' \
found in both documents regardless of order") or explain what's missing.

**Rule 3 — Bank Account from IRPF**
From the "Impuesto sobre la Renta" document, verify that a valid bank account \
is present, broken down into its five component parts:
- **Iban**: Country code + check digits (e.g., ES37)
- **Bank**: 4-digit bank code (e.g., 2085)
- **Branch**: 4-digit branch code (e.g., 9405)
- **DC**: 2-digit control digits (e.g., 52)
- **Account**: Account number (e.g., 032345678)
All five components must be present and valid.

Status: "pass" if all five bank account components are found, "fail" otherwise.
Detail: State each bank account component found, or explain what's missing.

**Rule 4 — CSV Code from IRPF**
From the "Impuesto sobre la Renta" document, verify that a valid CSV (Código \
Seguro de Verificación) code is present. The CSV is a unique verification code \
that authenticates the document.

Status: "pass" if a valid CSV code is found, "fail" otherwise.
Detail: State the CSV code found, or explain that it is missing.

**Rule 5 — CEA Code Consistency in Vida Laboral**
In the Vida Laboral document, if there are multiple pages, all pages must have \
the same CEA (Código de Cuenta de Cotización) code. The CEA code is used for \
validation purposes.

Status: "pass" if single page OR all pages have the same CEA code, "fail" if codes differ.
Detail: State the CEA code found, or list the different codes found across pages.

## Output Format

Respond with ONLY a JSON object — no markdown fencing, no extra text.

The output must have this exact structure:

{
  "title": "Validation",
  "statements": [
    {"rule": "Required Documents", "status": "pass|fail", "detail": "<explanation>"},
    {"rule": "Name Consistency", "status": "pass|fail", "detail": "<explanation>"},
    {"rule": "Bank Account", "status": "pass|fail", "detail": "<explanation>"},
    {"rule": "CSV Code", "status": "pass|fail", "detail": "<explanation>"},
    {"rule": "CEA Code Consistency", "status": "pass|fail", "detail": "<explanation>"}
  ]
}

## Example Output

{
  "title": "Validation",
  "statements": [
    {"rule": "Required Documents", "status": "pass", "detail": "Both IRPF and Vida Laboral documents found."},
    {"rule": "Name Consistency", "status": "pass", "detail": "Name parts 'Juan', 'García', 'López' found in both documents regardless of order."},
    {"rule": "Bank Account", "status": "pass", "detail": "IBAN prefix ES37, Bank 2085, Branch 9405, DC 52, Account 032345678 found in IRPF."},
    {"rule": "CSV Code", "status": "pass", "detail": "CSV code ABC123 found in IRPF."},
    {"rule": "CEA Code Consistency", "status": "fail", "detail": "CEA code differs between page 1 (12345) and page 3 (67890)."}
  ]
}

Always include all five rules in your response, even if some cannot be evaluated \
due to missing data. In such cases, mark status as "fail" and explain what data \
is missing in the detail field.
"""


async def create_validation_agent():
    """Create the PersonalInformationValidationAgent in Azure AI Foundry and print its details."""

    endpoint = os.environ.get("AZURE_AI_PROJECT_ENDPOINT")
    model = os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME")

    if not endpoint:
        raise ValueError("AZURE_AI_PROJECT_ENDPOINT environment variable is required")
    if not model:
        raise ValueError(
            "AZURE_AI_MODEL_DEPLOYMENT_NAME environment variable is required"
        )

    async with DefaultAzureCredential() as credential:
        async with AIProjectClient(
            endpoint=endpoint, credential=credential
        ) as project_client:
            definition = PromptAgentDefinition(
                model=model,
                instructions=VALIDATION_INSTRUCTIONS,
            )

            agent = await project_client.agents.create_version(
                agent_name="PersonalInformationValidationAgent",
                definition=definition,
            )

            print("✅ Agent created successfully!")
            print(f"   Name:  {agent.name}")
            print(f"   ID:    {agent.id}")
            print(f"   Model: {model}")

            # Extract base endpoint (strip project path) for Function App config
            base_endpoint = endpoint.split("/api/projects")[0] if "/api/projects" in endpoint else endpoint
            print(f"\n📋 For Function App deployment, set:")
            print(f"   FOUNDRY_AGENT_ENDPOINT={base_endpoint}")
            print(f"   VALIDATION_AGENT_APP_NAME=personal-info-validator")

            return agent


if __name__ == "__main__":
    asyncio.run(create_validation_agent())
