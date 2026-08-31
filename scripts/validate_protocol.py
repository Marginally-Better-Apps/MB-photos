#!/usr/bin/env python3
"""Dependency-free structural checks for the checked-in protocol-v1 contract."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = ROOT / "protocol"


def fail(message: str) -> None:
    raise SystemExit(f"protocol validation failed: {message}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{path.relative_to(ROOT)}: {error}")


def json_pointer(document: Any, pointer: str, source: str) -> Any:
    if pointer in ("", "/"):
        return document
    value = document
    for encoded in pointer.lstrip("/").split("/"):
        key = encoded.replace("~1", "/").replace("~0", "~")
        try:
            value = value[int(key)] if isinstance(value, list) else value[key]
        except (KeyError, IndexError, TypeError, ValueError):
            fail(f"unresolved JSON pointer {pointer!r} in {source}")
    return value


def visit_refs(value: Any, source_path: Path, documents: dict[Path, Any]) -> None:
    if isinstance(value, dict):
        reference = value.get("$ref")
        if isinstance(reference, str) and not reference.startswith(("https://", "http://")):
            file_part, _, fragment = reference.partition("#")
            target_path = (source_path.parent / file_part).resolve() if file_part else source_path.resolve()
            if target_path not in documents:
                if not target_path.is_file():
                    fail(f"{source_path.relative_to(ROOT)} references missing {file_part!r}")
                documents[target_path] = load_json(target_path)
            json_pointer(documents[target_path], fragment, str(source_path.relative_to(ROOT)))
        for child in value.values():
            visit_refs(child, source_path, documents)
    elif isinstance(value, list):
        for child in value:
            visit_refs(child, source_path, documents)


def main() -> None:
    required = [
        PROTOCOL / "openapi.yaml",
        PROTOCOL / "schemas/v1/models.schema.json",
        PROTOCOL / "schemas/v1/api.schema.json",
        PROTOCOL / "fixtures/v1/_fixture-map.json",
        PROTOCOL / "test-vectors/windows-paths.json",
    ]
    missing = [str(path.relative_to(ROOT)) for path in required if not path.is_file()]
    if missing:
        fail("missing required files: " + ", ".join(missing))

    json_paths = sorted(PROTOCOL.rglob("*.json"))
    documents = {path.resolve(): load_json(path) for path in json_paths}
    for path in json_paths:
        visit_refs(documents[path.resolve()], path, documents)

    fixture_map_path = PROTOCOL / "fixtures/v1/_fixture-map.json"
    fixture_map = documents[fixture_map_path.resolve()]
    if not isinstance(fixture_map, dict) or not fixture_map:
        fail("fixture map must be a non-empty object")
    for filename, target in fixture_map.items():
        fixture_path = fixture_map_path.parent / filename
        if not fixture_path.is_file():
            fail(f"fixture map references missing {filename}")
        if not isinstance(target, str) or "#" not in target:
            fail(f"fixture map target for {filename} is not a schema pointer")
        schema_name, _, pointer = target.partition("#")
        schema_path = (PROTOCOL / "schemas/v1" / schema_name).resolve()
        if schema_path not in documents:
            fail(f"fixture {filename} references missing schema {schema_name}")
        json_pointer(documents[schema_path], pointer, filename)

    vectors = documents[(PROTOCOL / "test-vectors/windows-paths.json").resolve()]
    if vectors.get("policyVersion") != 1:
        fail("Windows path policyVersion must be 1")
    if vectors.get("constants", {}).get("maxRelativePathUtf16Units") != 239:
        fail("Windows path maximum must remain 239 UTF-16 units in protocol v1")
    for section in (
        "sanitizeFilename",
        "validateRelativePath",
        "shortenRelativePath",
        "resolveCaseInsensitiveCollision",
    ):
        cases = vectors.get(section)
        if not isinstance(cases, list) or not cases:
            fail(f"Windows path vector section {section} must be non-empty")
        identifiers = [case.get("id") for case in cases]
        if any(not identifier for identifier in identifiers) or len(set(identifiers)) != len(identifiers):
            fail(f"Windows path vector section {section} has missing or duplicate ids")

    openapi = (PROTOCOL / "openapi.yaml").read_text(encoding="utf-8")
    if not re.search(r"^openapi:\s*3\.", openapi, re.MULTILINE):
        fail("openapi.yaml does not declare OpenAPI 3.x")
    for endpoint in (
        "/v1/pair:",
        "/v1/jobs:",
        "/v1/jobs/{jobId}:",
        "/v1/jobs/{jobId}/files/{fileId}/chunks/{chunkIndex}:",
        "/v1/jobs/{jobId}/files/{fileId}/commit:",
        "/v1/jobs/{jobId}/complete:",
        "/v1/jobs/{jobId}/abandon:",
    ):
        if endpoint not in openapi:
            fail(f"openapi.yaml is missing {endpoint[:-1]}")

    print(
        f"protocol v1 structure is valid: {len(json_paths)} JSON files, "
        f"{len(fixture_map)} fixtures, and "
        f"{sum(len(vectors[name]) for name in ('sanitizeFilename', 'validateRelativePath', 'shortenRelativePath', 'resolveCaseInsensitiveCollision'))} path vectors"
    )


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
