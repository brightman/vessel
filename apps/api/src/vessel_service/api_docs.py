"""Vessel-branded Scalar reference, backed by this app's OpenAPI document."""

from fastapi import FastAPI, Request
from scalar_fastapi import AgentScalarConfig, Theme, get_scalar_api_reference

SCALAR_JS_URL = "https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.74.0"
VESSEL_DOCS_CSS = """
:root {
  --scalar-font: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
  --scalar-font-code: ui-monospace, "SFMono-Regular", Consolas, monospace;
}
.light-mode {
  --scalar-color-accent: #386ef3;
  --scalar-background-1: #ffffff;
  --scalar-background-2: #fbfaf8;
  --scalar-background-3: #f0efec;
  --scalar-color-1: #20201e;
  --scalar-color-2: #595852;
  --scalar-border-color: #e9e7e2;
}
.dark-mode {
  --scalar-color-accent: #91adff;
  --scalar-background-1: #191a1d;
  --scalar-background-2: #202125;
  --scalar-background-3: #2b2d33;
  --scalar-color-1: #f5f4ef;
  --scalar-color-2: #bbbcbf;
  --scalar-border-color: #34363c;
}
"""


API_TAGS = [
    {"name": "auth", "description": "Sign in and manage your Vessel session."},
    {
        "name": "spaces",
        "description": "Personal spaces, teams, invitations and member roles.",
    },
    {
        "name": "files",
        "description": "Folders, sharing, uploads, file versions and trash.",
    },
    {"name": "notes", "description": "Read and edit block-based documents."},
    {"name": "note-agent-runs", "description": "Start, stream and cancel Note Agent Runs."},
    {"name": "note-proposals", "description": "Review and accept Agent edit proposals."},
    {"name": "note-agent-events", "description": "Replay Note Agent proposal lifecycle events."},
    {"name": "private-notes-mcp", "description": "Run-scoped MCP tools for the configured Note Agent."},
    {"name": "directories", "description": "Organize Notes within a space."},
    {
        "name": "note-versions",
        "description": "Note history, checkpoints and restoration.",
    },
    {"name": "assets", "description": "Images attached to Notes."},
    {"name": "apps", "description": "Structured tables, manifests and records."},
    {"name": "system", "description": "Service liveness and database readiness."},
]


def add_api_docs(app: FastAPI) -> None:
    @app.get("/docs", include_in_schema=False)
    async def scalar_docs(request: Request):
        root_path = request.scope.get("root_path", "").rstrip("/")
        return get_scalar_api_reference(
            openapi_url=f"{root_path}{app.openapi_url}",
            title="Karama.Cloud API Reference",
            scalar_js_url=SCALAR_JS_URL,
            scalar_favicon_url="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='9' fill='%23252521'/%3E%3Cpath d='m8 9 8 15 8-15' fill='none' stroke='white' stroke-width='3'/%3E%3C/svg%3E",
            theme=Theme.DEFAULT,
            custom_css=VESSEL_DOCS_CSS,
            with_default_fonts=False,
            dark_mode=False,
            show_developer_tools="never",
            persist_auth=False,
            telemetry=False,
            agent=AgentScalarConfig(disabled=True),
            scalar_proxy_url="",
        )
