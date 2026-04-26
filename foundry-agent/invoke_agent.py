"""
Invoke the Email Classifier Agent via the Azure AI Foundry Responses API.

Supports two invocation modes:
  1. Agent Application (published) — calls the Responses protocol endpoint
  2. Project-level agent              — calls the project-scoped Responses endpoint

Both use the stateless Responses API, consistent with how the Logic App calls
the agent.

Prerequisites:
  - Azure CLI login (`az login`) or another credential recognized by
    DefaultAzureCredential.
  - Environment variables (see below).

Required env vars:
  AZURE_AI_PROJECT_ENDPOINT   Your Azure AI Foundry project endpoint
                               e.g. https://<account>.services.ai.azure.com/api/projects/<project>

Optional env vars:
  APPLICATION_NAME            Agent Application name (default: email-classifier)
  AGENT_NAME                  Project-level agent name (default: EmailClassifierAgent)

Usage:
  # Invoke published Agent Application (default)
  python invoke_agent.py

  # Invoke with a custom message
  python invoke_agent.py "Subject: Reset my password\\nBody: I can't log in."

  # Invoke the project-level agent instead
  python invoke_agent.py --project-agent

  # Interactive mode
  python invoke_agent.py --interactive
"""

import argparse
import asyncio
import json
import os
import sys
import urllib.request
from urllib.error import HTTPError

from azure.identity.aio import DefaultAzureCredential

# Auth audience for Azure AI Foundry
AI_FOUNDRY_AUDIENCE = "https://ai.azure.com"

# Default sample email for quick testing
DEFAULT_EMAIL = (
    "Subject: Update my mailing address\n"
    "Body: Hi, I recently moved and need to update the mailing address on my "
    "account (ID: ACC-44221). My new address is 742 Evergreen Terrace, "
    "Springfield. Please confirm once updated. Thanks!"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Invoke the Email Classifier Agent via the Responses API."
    )
    parser.add_argument(
        "message",
        nargs="?",
        default=None,
        help="Email text to classify. Uses a sample email if omitted.",
    )
    parser.add_argument(
        "--project-agent",
        action="store_true",
        help="Invoke the project-level agent instead of the published Agent Application.",
    )
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="Enter messages interactively in a loop.",
    )
    return parser.parse_args()


def build_responses_url(endpoint: str, application_name: str | None = None) -> str:
    """Build the Responses API URL.

    For an Agent Application:
      {endpoint}/applications/{app}/protocols/openai/responses
    For a project-level agent:
      {endpoint}/openai/responses
    """
    base = endpoint.rstrip("/")
    if application_name:
        return (
            f"{base}/applications/{application_name}"
            f"/protocols/openai/responses?api-version=2025-11-15-preview"
        )
    return f"{base}/openai/responses?api-version=2025-11-15-preview"


async def get_access_token() -> str:
    """Acquire a bearer token scoped to Azure AI Foundry."""
    async with DefaultAzureCredential() as credential:
        token = await credential.get_token(f"{AI_FOUNDRY_AUDIENCE}/.default")
        return token.token


def call_responses_api(
    url: str,
    token: str,
    message: str,
    agent_name: str | None = None,
) -> dict:
    """Send a stateless Responses API request and return the parsed response.

    Args:
        url:        Full Responses API URL.
        token:      Bearer token.
        message:    The user message (email text).
        agent_name: For project-level agents, the agent name to target.
    """
    payload: dict = {"input": message}
    if agent_name:
        # Project-level agents require the agent name in the request
        payload["agent"] = {"name": agent_name, "type": "agent_reference"}

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        raise RuntimeError(
            f"Responses API returned HTTP {exc.code}: {body}"
        ) from exc


def extract_text(response: dict) -> str:
    """Pull the agent's text from the Responses API output.

    The Responses API returns an 'output' array; each item with
    type 'message' contains a 'content' list of text blocks.
    """
    for item in response.get("output", []):
        if item.get("type") == "message" and item.get("role") == "assistant":
            parts = item.get("content", [])
            return "".join(
                p.get("text", "") for p in parts if p.get("type") == "output_text"
            )
    # Fallback: some responses put text at the top level
    if "output_text" in response:
        return response["output_text"]
    return json.dumps(response, indent=2)


async def invoke(message: str, use_project_agent: bool = False) -> str:
    """High-level helper: authenticate, call the agent, return text."""
    endpoint = os.environ.get("AZURE_AI_PROJECT_ENDPOINT", "")
    if not endpoint:
        raise ValueError(
            "Set AZURE_AI_PROJECT_ENDPOINT to your Foundry project endpoint.\n"
            "Example: https://<account>.services.ai.azure.com/api/projects/<project>"
        )

    if use_project_agent:
        agent_name = os.environ.get("AGENT_NAME", "EmailClassifierAgent")
        url = build_responses_url(endpoint)
        print(f"🔗 Target: project agent '{agent_name}'")
    else:
        app_name = os.environ.get("APPLICATION_NAME", "email-classifier")
        agent_name = None
        url = build_responses_url(endpoint, application_name=app_name)
        print(f"🔗 Target: Agent Application '{app_name}'")

    print(f"📡 URL:    {url}\n")

    print("🔑 Acquiring token...")
    token = await get_access_token()

    print("📨 Sending request...\n")
    response = call_responses_api(url, token, message, agent_name=agent_name)

    return extract_text(response)


async def interactive_loop(use_project_agent: bool) -> None:
    """Run an interactive prompt loop."""
    print("📧 Email Classifier — Interactive Mode")
    print("   Type an email (subject + body) and press Enter.")
    print("   Type 'quit' or 'exit' to stop.\n")

    while True:
        try:
            user_input = input("✉️  Email> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nBye!")
            break

        if user_input.lower() in ("quit", "exit", "q"):
            print("Bye!")
            break
        if not user_input:
            continue

        try:
            result = await invoke(user_input, use_project_agent)
            print(f"🤖 Agent response:\n{result}\n")
        except Exception as exc:
            print(f"❌ Error: {exc}\n", file=sys.stderr)


async def main() -> None:
    args = parse_args()

    if args.interactive:
        await interactive_loop(args.project_agent)
        return

    message = args.message or DEFAULT_EMAIL
    print(f"📧 Input message:\n{message}\n")
    print("─" * 60)

    try:
        result = await invoke(message, args.project_agent)
        print(f"🤖 Agent response:\n{result}")
    except Exception as exc:
        print(f"❌ Error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
