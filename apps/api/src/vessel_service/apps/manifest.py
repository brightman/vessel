"""Vessel subset of Baizhi Apps Manifest and value validation rules.

Adapted from baizhi_agent_runtime/apps/{manifest,sql_identifiers,value_validation}.py.
App Runtime policies, row ACL, H5, field agents, and raw SQL are deliberately absent.
"""

import json
import re
import uuid
from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from typing import Any


TYPES = {"text", "integer", "numeric", "boolean", "timestamp", "uuid", "json"}
SYSTEM_FIELDS = {"id", "created_at", "updated_at", "created_by", "updated_by", "row_version", "deleted_at", "owner_id", "permission"}
IDENTIFIER = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")
RESERVED = {"select", "insert", "update", "delete", "drop", "alter", "create", "table", "schema", "user"}


class ManifestError(ValueError):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def identifier(value: Any) -> str:
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value) or value in RESERVED:
        raise ManifestError("APP_MANIFEST_INVALID")
    return value


def normalize_manifest(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict) or set(raw) != {"tables"}:
        raise ManifestError("APP_MANIFEST_INVALID")
    tables = raw["tables"]
    if not isinstance(tables, dict) or not tables or len(tables) > 50:
        raise ManifestError("APP_MANIFEST_INVALID")
    output = {}
    for table_name, table in tables.items():
        identifier(table_name)
        if not isinstance(table, dict) or set(table) != {"fields"}:
            raise ManifestError("APP_MANIFEST_INVALID")
        fields = table["fields"]
        if not isinstance(fields, dict) or not fields or len(fields) > 100:
            raise ManifestError("APP_MANIFEST_INVALID")
        normalized = {}
        for field_name, definition in fields.items():
            identifier(field_name)
            if field_name in SYSTEM_FIELDS:
                raise ManifestError("APP_MANIFEST_INVALID")
            if (not isinstance(definition, dict) or set(definition) != {"type", "nullable"}
                    or not isinstance(definition["type"], str) or definition["type"] not in TYPES
                    or not isinstance(definition["nullable"], bool)):
                raise ManifestError("APP_MANIFEST_INVALID")
            normalized[field_name] = dict(definition)
        output[table_name] = {"fields": normalized}
    return {"tables": output}


def check_additive_manifest(old: dict, new: dict) -> None:
    for table_name, old_table in old["tables"].items():
        new_table = new["tables"].get(table_name)
        if new_table is None:
            raise ManifestError("APP_SCHEMA_CHANGE_UNSUPPORTED")
        for field_name, old_definition in old_table["fields"].items():
            if new_table["fields"].get(field_name) != old_definition:
                raise ManifestError("APP_SCHEMA_CHANGE_UNSUPPORTED")
        for field_name, definition in new_table["fields"].items():
            if field_name not in old_table["fields"] and not definition["nullable"]:
                raise ManifestError("APP_SCHEMA_CHANGE_UNSUPPORTED")


def normalize_value(definition: dict, value: Any) -> Any:
    if value is None:
        if definition["nullable"]:
            return None
        raise ManifestError("APP_FIELD_VALUE_INVALID")
    kind = definition["type"]
    if kind == "text" and isinstance(value, str):
        return value
    if kind == "integer" and isinstance(value, int) and not isinstance(value, bool) and -(2**31) <= value < 2**31:
        return value
    if kind == "numeric" and not isinstance(value, bool) and isinstance(value, (int, float, str)):
        try:
            raw = str(value)
            if len(raw) > 128:
                raise ManifestError("APP_FIELD_VALUE_INVALID")
            number = Decimal(raw)
            digits = number.as_tuple().digits
            exponent = number.as_tuple().exponent
            if (number.is_finite() and len(digits) <= 38
                    and -18 <= exponent <= 37 and number.adjusted() <= 37):
                return format(number, "f")
        except (InvalidOperation, ValueError):
            pass
    if kind == "boolean" and isinstance(value, bool):
        return value
    if kind == "timestamp" and isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo:
                return parsed.astimezone(UTC).isoformat()
        except ValueError:
            pass
    if kind == "uuid" and isinstance(value, str):
        try:
            return str(uuid.UUID(value))
        except ValueError:
            pass
    if kind == "json":
        try:
            json.dumps(value, allow_nan=False)
            return value
        except (TypeError, ValueError):
            pass
    raise ManifestError("APP_FIELD_VALUE_INVALID")


def normalize_record(fields: dict, values: Any, *, creating: bool) -> dict:
    if not isinstance(values, dict) or not values or any(key not in fields for key in values):
        raise ManifestError("APP_FIELD_VALUE_INVALID")
    result = {key: normalize_value(fields[key], value) for key, value in values.items()}
    if creating:
        for key, definition in fields.items():
            if key not in result:
                if not definition["nullable"]:
                    raise ManifestError("APP_FIELD_VALUE_INVALID")
                result[key] = None
    return result
