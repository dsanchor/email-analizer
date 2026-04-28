import azure.functions as func
import json
import logging
from datetime import datetime, timezone
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
import os
import urllib.request
from urllib.error import HTTPError

app = func.FunctionApp()

# Environment variables
COSMOS_ENDPOINT = os.environ.get("COSMOS_ENDPOINT")
COSMOS_DATABASE = os.environ.get("COSMOS_DATABASE", "email-analyzer-db")
COSMOS_CONTAINER = os.environ.get("COSMOS_CONTAINER", "emails")
FOUNDRY_AGENT_ENDPOINT = os.environ.get("FOUNDRY_AGENT_ENDPOINT")
VALIDATION_AGENT_NAME = os.environ.get("VALIDATION_AGENT_NAME", "PersonalInformationValidationAgent")

# Initialize Cosmos client with managed identity
credential = DefaultAzureCredential()
cosmos_client = CosmosClient(COSMOS_ENDPOINT, credential=credential)
database = cosmos_client.get_database_client(COSMOS_DATABASE)
container = database.get_container_client(COSMOS_CONTAINER)


def get_ai_foundry_token():
    """Get an access token for Azure AI Foundry."""
    token = credential.get_token("https://ai.azure.com/.default")
    return token.token


def call_validation_agent(document_data):
    """
    Call the PersonalInformationValidationAgent via the Responses API.
    
    Args:
        document_data: String representation of document/attachment data to validate
        
    Returns:
        dict: Parsed JSON response from the agent, or error structure
    """
    if not FOUNDRY_AGENT_ENDPOINT:
        logging.error("FOUNDRY_AGENT_ENDPOINT not configured")
        return {
            "title": "Validation",
            "error": "Agent endpoint not configured",
            "statements": []
        }
    
    try:
        # Build the Responses API URL — project-level endpoint, same as Logic App
        url = f"{FOUNDRY_AGENT_ENDPOINT}/openai/responses?api-version=2025-11-15-preview"
        
        logging.info(f"Calling validation agent at {url}")
        
        # Get access token
        token = get_ai_foundry_token()
        
        # Prepare request payload with agent reference (same pattern as Logic App)
        payload = {
            "input": document_data,
            "agent": {
                "name": VALIDATION_AGENT_NAME,
                "type": "agent_reference"
            }
        }
        data = json.dumps(payload).encode("utf-8")
        
        # Make HTTP request
        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        
        with urllib.request.urlopen(req, timeout=120) as resp:
            response = json.loads(resp.read().decode("utf-8"))
            
        # Extract the agent's response text
        agent_text = extract_agent_response(response)
        
        # Parse the JSON response from the agent
        try:
            agent_result = json.loads(agent_text)
            logging.info(f"Agent returned validation result: {agent_result}")
            return agent_result
        except json.JSONDecodeError as e:
            logging.error(f"Failed to parse agent response as JSON: {e}")
            logging.error(f"Agent response text: {agent_text}")
            return {
                "title": "Validation",
                "error": "Agent response was not valid JSON",
                "raw_response": agent_text,
                "statements": []
            }
            
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        logging.error(f"Validation agent HTTP error {exc.code}: {body}")
        return {
            "title": "Validation",
            "error": f"HTTP {exc.code}: {body}",
            "statements": []
        }
    except Exception as e:
        logging.error(f"Error calling validation agent: {str(e)}", exc_info=True)
        return {
            "title": "Validation",
            "error": str(e),
            "statements": []
        }


def extract_agent_response(response):
    """
    Extract the agent's text from the Responses API output.
    
    The Responses API returns an 'output' array with items of type 'message'
    containing 'content' arrays with text blocks.
    """
    for item in response.get("output", []):
        if item.get("type") == "message" and item.get("role") == "assistant":
            parts = item.get("content", [])
            return "".join(
                p.get("text", "") for p in parts if p.get("type") == "output_text"
            )
    # Fallback
    if "output_text" in response:
        return response["output_text"]
    return json.dumps(response, indent=2)


@app.cosmos_db_trigger(
    arg_name="documents",
    container_name="emails",
    database_name="email-analyzer-db",
    connection="COSMOS_CONNECTION",
    lease_container_name="leases",
    create_lease_container_if_not_exists=True
)
def process_classified_emails(documents: func.DocumentList):
    """
    Processes email documents from Cosmos DB change feed.
    Checks if the last statusHistory entry is "Email classified".
    If so, appends "Processed by agent" status and adds agentResult field.
    """
    if not documents:
        logging.info("No documents in change feed batch")
        return

    logging.info(f"Processing {len(documents)} document(s) from change feed")

    for doc in documents:
        try:
            doc_dict = json.loads(doc.to_json())
            doc_id = doc_dict.get("id")
            message_id = doc_dict.get("messageId")
            status_history = doc_dict.get("statusHistory", [])

            logging.info(f"Processing document {doc_id} (messageId: {message_id})")

            # Check if there's a statusHistory array
            if not status_history or not isinstance(status_history, list):
                logging.info(f"Document {doc_id} has no statusHistory, skipping")
                continue

            # Get the last status entry
            last_status_entry = status_history[-1]
            last_status = last_status_entry.get("status", "")

            logging.info(f"Document {doc_id} last status: {last_status}")

            # Only process if last status is "Email classified"
            if last_status != "Email classified":
                logging.info(f"Document {doc_id} status is not 'Email classified', skipping")
                continue

            # Check if already processed (avoid duplicate processing)
            if any(s.get("status") == "Processed by agent" for s in status_history):
                logging.info(f"Document {doc_id} already processed by agent, skipping")
                continue

            logging.info(f"Processing document {doc_id} - calling validation agent")

            # Prepare document data for validation
            # Extract attachments and relevant content
            attachments = doc_dict.get("attachments", [])
            subject = doc_dict.get("subject", "")
            body = doc_dict.get("body", "")
            
            # Build input for the agent
            document_data = {
                "subject": subject,
                "body": body,
                "attachments": attachments,
                "messageId": message_id
            }
            
            document_data_str = json.dumps(document_data, indent=2)
            
            # Call the validation agent
            agent_result = call_validation_agent(document_data_str)
            
            # Append new status to statusHistory
            status = "Processed by agent" if "error" not in agent_result else "Agent processing failed"
            new_status = {
                "status": status,
                "timestamp": datetime.now(timezone.utc).isoformat()
            }
            status_history.append(new_status)

            # Update the document in Cosmos DB
            doc_dict["statusHistory"] = status_history
            doc_dict["agentResult"] = agent_result

            # Upsert — partition key is extracted from the document body automatically
            container.upsert_item(body=doc_dict)

            logging.info(f"Successfully updated document {doc_id} with agent result")

        except Exception as e:
            logging.error(f"Error processing document: {str(e)}", exc_info=True)
            # Continue processing other documents even if one fails
            continue
