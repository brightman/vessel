"""Validate the versioned, untrusted auto Agent response."""
import json
import re
from urllib.parse import urlsplit
from vessel_service.proposals.agent_output import parse_agent_proposal
from vessel_service.proposals.service import ProposalError


def parse_agent_response(output_text: object, *, base_revision: int) -> dict:
    def invalid():
        raise ProposalError("INVALID_AGENT_RESPONSE_SCHEMA")
    if not isinstance(output_text, str) or len(output_text.encode()) > 2_000_000:
        invalid()
    try:
        text = output_text.strip()
        if text.startswith("```"):
            fenced = re.fullmatch(r"```(?:json)?\s*\n(.*?)\n```", text, flags=re.DOTALL)
            if not fenced:
                raise ValueError("ambiguous fence")
            text = fenced.group(1).strip()
        elif not text.startswith("{"):
            # A model may put a bracketed prose list before its JSON response.
            # Accept only one trailing object after prose, never a leading JSON
            # array, a prior object, or a code fence. Validate the payload below.
            start = text.find("{")
            if (start < 0 or start > 4_096 or text.startswith("[")
                    or any(c in text[:start] for c in "{}`")):
                raise ValueError("ambiguous prefix")
            text = text[start:]
        value = json.loads(text)
    except (ValueError, TypeError) as error:
        raise ProposalError("INVALID_AGENT_RESPONSE_JSON") from error
    if not isinstance(value, dict) or not {"schema_version", "type", "message"} <= value.keys():
        invalid()
    if type(value["schema_version"]) is not int or value["schema_version"] != 1 or value["type"] not in ("answer", "clarification", "edit"):
        invalid()
    allowed = {"schema_version", "type", "message", "sources"} | ({"options"} if value["type"] == "clarification" else {"proposal"} if value["type"] == "edit" else set())
    if value.keys() - allowed or not isinstance(value["message"], str) or not value["message"].strip() or len(value["message"]) > 20_000:
        invalid()
    if "sources" in value:
        if not isinstance(value["sources"], list) or len(value["sources"]) > 30:
            invalid()
        for source in value["sources"]:
            if not isinstance(source, dict) or set(source) != {"title", "url"} or not isinstance(source["title"], str) or not 1 <= len(source["title"]) <= 500 or not isinstance(source["url"], str):
                invalid()
            try:
                url = urlsplit(source["url"])
                if url.scheme not in ("https", "http") or not url.hostname or url.username or url.password or any(ord(c) < 33 for c in source["url"]) or len(source["url"]) > 4000:
                    invalid()
            except ValueError:
                invalid()
    if value["type"] == "clarification" and "options" in value:
        options = value["options"]
        if not isinstance(options, list) or not 1 <= len(options) <= 8:
            invalid()
        ids = set()
        for option in options:
            if not isinstance(option, dict) or set(option) != {"id", "label"} or any(not isinstance(option[k], str) or not option[k].strip() or len(option[k]) > (128 if k == "id" else 500) for k in ("id", "label")) or option["id"] in ids:
                invalid()
            ids.add(option["id"])
    if value["type"] == "edit":
        if "proposal" not in value:
            invalid()
        parse_agent_proposal(json.dumps(value["proposal"]), base_revision=base_revision)
    return value
