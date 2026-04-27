import azure.functions as func
import json
import logging
from datetime import datetime, timezone
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
import os

app = func.FunctionApp()

# Environment variables
COSMOS_ENDPOINT = os.environ.get("COSMOS_ENDPOINT")
COSMOS_DATABASE = os.environ.get("COSMOS_DATABASE", "email-analyzer-db")
COSMOS_CONTAINER = os.environ.get("COSMOS_CONTAINER", "emails")

# Initialize Cosmos client with managed identity
credential = DefaultAzureCredential()
cosmos_client = CosmosClient(COSMOS_ENDPOINT, credential=credential)
database = cosmos_client.get_database_client(COSMOS_DATABASE)
container = database.get_container_client(COSMOS_CONTAINER)


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

            logging.info(f"Processing document {doc_id} - appending agent result")

            # Append new status to statusHistory
            new_status = {
                "status": "Processed by agent",
                "timestamp": datetime.now(timezone.utc).isoformat()
            }
            status_history.append(new_status)

            # Add agentResult field
            agent_result = {
                "title": "Validation",
                "statements": [
                    "DNIs match",
                    "Birthday match",
                    "Same name and surname"
                ]
            }

            # Update the document in Cosmos DB
            doc_dict["statusHistory"] = status_history
            doc_dict["agentResult"] = agent_result

            # Use partition key for the update
            container.upsert_item(
                body=doc_dict,
                partition_key=message_id
            )

            logging.info(f"Successfully updated document {doc_id} with agent result")

        except Exception as e:
            logging.error(f"Error processing document: {str(e)}", exc_info=True)
            # Continue processing other documents even if one fails
            continue
