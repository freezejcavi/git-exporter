#!/usr/bin/env python3
import json
import re
import sys

REDACTED = "<redacted>"
SENSITIVE_KEY = re.compile(
    r"(?:^|[_-])(password|passwd|token|api[_-]?key|secret|private[_-]?key|client[_-]?secret|credential|access[_-]?key|refresh[_-]?token)(?:$|[_-])",
    re.IGNORECASE,
)


def schema_is_password(schema):
    if isinstance(schema, str):
        return "password" in schema.lower()
    return False


def is_sensitive_key(key, value):
    # Keep non-secret control flags such as check_for_secrets: true visible.
    if isinstance(value, (bool, int, float)) or value is None:
        return False
    return bool(SENSITIVE_KEY.search(str(key)))


def sanitize(value, schema=None, key=None):
    if schema_is_password(schema):
        return REDACTED

    if key is not None and is_sensitive_key(key, value):
        return REDACTED

    if isinstance(value, dict):
        schema_dict = schema if isinstance(schema, dict) else {}
        return {
            child_key: sanitize(child_value, schema_dict.get(child_key), child_key)
            for child_key, child_value in value.items()
        }

    if isinstance(value, list):
        item_schema = None
        if isinstance(schema, list) and schema:
            item_schema = schema[0]
        return [sanitize(item, item_schema) for item in value]

    return value


def main():
    info = json.load(sys.stdin)
    options = info.get("options") or {}
    schema = info.get("schema") or {}

    output = {
        "name": info.get("name"),
        "slug": info.get("slug"),
        "version": info.get("version"),
        "state": info.get("state"),
        "boot": info.get("boot"),
        "auto_update": info.get("auto_update"),
        "watchdog": info.get("watchdog"),
        "protected": info.get("protected"),
        "options": sanitize(options, schema),
    }

    json.dump(output, sys.stdout, indent=2, sort_keys=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
