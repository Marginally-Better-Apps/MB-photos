#!/usr/bin/env python3
"""Validate protocol JSON, local references, fixtures, OpenAPI YAML, and path vectors.

This intentionally uses only the Python standard library plus macOS/system Ruby for
YAML parsing, so it can run before either application toolchain is installed. The
small schema evaluator implements the JSON Schema keywords used by this contract;
application test suites should still use their production JSON Schema libraries.
"""

import json
import re
import subprocess
import sys
import unicodedata
from datetime import datetime
from pathlib import Path


PROTOCOL_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = PROTOCOL_ROOT / "schemas" / "v1"
FIXTURE_ROOT = PROTOCOL_ROOT / "fixtures" / "v1"
VECTOR_PATH = PROTOCOL_ROOT / "test-vectors" / "windows-paths.json"
OPENAPI_PATH = PROTOCOL_ROOT / "openapi.yaml"

ERRORS = []
DOCUMENT_CACHE = {}


def fail(message):
    ERRORS.append(message)


def load_json(path):
    path = path.resolve()
    if path not in DOCUMENT_CACHE:
        try:
            with path.open("r", encoding="utf-8") as handle:
                DOCUMENT_CACHE[path] = json.load(handle)
        except Exception as exc:
            fail("{}: cannot parse JSON: {}".format(path.relative_to(PROTOCOL_ROOT), exc))
            DOCUMENT_CACHE[path] = None
    return DOCUMENT_CACHE[path]


def json_pointer(document, fragment, label):
    if not fragment:
        return document
    if fragment.startswith("/"):
        value = document
        try:
            for raw_part in fragment[1:].split("/"):
                part = raw_part.replace("~1", "/").replace("~0", "~")
                value = value[int(part)] if isinstance(value, list) else value[part]
            return value
        except (KeyError, IndexError, TypeError, ValueError):
            fail("{}: unresolved JSON pointer #{}".format(label, fragment))
            return None

    def find_anchor(value):
        if isinstance(value, dict):
            if value.get("$anchor") == fragment:
                return value
            for child in value.values():
                result = find_anchor(child)
                if result is not None:
                    return result
        elif isinstance(value, list):
            for child in value:
                result = find_anchor(child)
                if result is not None:
                    return result
        return None

    result = find_anchor(document)
    if result is None:
        fail("{}: unresolved anchor #{}".format(label, fragment))
    return result


def resolve_ref(ref, current_path):
    base, separator, fragment = ref.partition("#")
    if base.startswith("http://") or base.startswith("https://"):
        fail("{}: remote references are not permitted by the local validator".format(ref))
        return None, current_path
    target_path = (current_path.parent / base).resolve() if base else current_path.resolve()
    document = load_json(target_path)
    if document is None:
        return None, target_path
    target = json_pointer(document, fragment if separator else "", str(target_path))
    return target, target_path


def is_type(instance, expected):
    if expected == "null":
        return instance is None
    if expected == "boolean":
        return isinstance(instance, bool)
    if expected == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if expected == "number":
        return isinstance(instance, (int, float)) and not isinstance(instance, bool)
    if expected == "string":
        return isinstance(instance, str)
    if expected == "array":
        return isinstance(instance, list)
    if expected == "object":
        return isinstance(instance, dict)
    return True


def schema_errors(instance, schema, current_path, location="$"):
    errors = []
    if schema is True:
        return errors
    if schema is False:
        return ["{}: schema is false".format(location)]
    if not isinstance(schema, dict):
        return ["{}: invalid schema node".format(location)]

    if "$ref" in schema:
        target, target_path = resolve_ref(schema["$ref"], current_path)
        if target is None:
            return ["{}: unresolved $ref {}".format(location, schema["$ref"])]
        errors.extend(schema_errors(instance, target, target_path, location))

    if "const" in schema and instance != schema["const"]:
        errors.append("{}: expected constant {!r}".format(location, schema["const"]))
    if "enum" in schema and instance not in schema["enum"]:
        errors.append("{}: value {!r} is not in enum".format(location, instance))

    if "type" in schema:
        expected_types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(is_type(instance, expected) for expected in expected_types):
            errors.append("{}: expected {}, got {}".format(location, expected_types, type(instance).__name__))
            return errors

    for branch in schema.get("allOf", []):
        errors.extend(schema_errors(instance, branch, current_path, location))

    if "oneOf" in schema:
        branch_errors = [schema_errors(instance, branch, current_path, location) for branch in schema["oneOf"]]
        successes = sum(1 for branch in branch_errors if not branch)
        if successes != 1:
            errors.append("{}: expected exactly one oneOf branch, got {}".format(location, successes))

    if "not" in schema and not schema_errors(instance, schema["not"], current_path, location):
        errors.append("{}: matched prohibited schema".format(location))

    if "if" in schema:
        condition_matches = not schema_errors(instance, schema["if"], current_path, location)
        selected = schema.get("then") if condition_matches else schema.get("else")
        if selected is not None:
            errors.extend(schema_errors(instance, selected, current_path, location))

    if isinstance(instance, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in instance:
                errors.append("{}: missing required property {!r}".format(location, key))
        properties = schema.get("properties", {})
        for key, child_schema in properties.items():
            if key in instance:
                errors.extend(schema_errors(instance[key], child_schema, current_path, location + "." + key))
        if schema.get("additionalProperties") is False:
            extras = sorted(set(instance) - set(properties))
            if extras:
                errors.append("{}: unexpected properties {}".format(location, extras))

    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            errors.append("{}: fewer than {} items".format(location, schema["minItems"]))
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            errors.append("{}: more than {} items".format(location, schema["maxItems"]))
        if schema.get("uniqueItems"):
            canonical = [json.dumps(value, sort_keys=True, separators=(",", ":")) for value in instance]
            if len(canonical) != len(set(canonical)):
                errors.append("{}: items are not unique".format(location))
        if "items" in schema:
            for index, child in enumerate(instance):
                errors.extend(schema_errors(child, schema["items"], current_path, "{}[{}]".format(location, index)))

    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            errors.append("{}: shorter than minLength".format(location))
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            errors.append("{}: longer than maxLength".format(location))
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            errors.append("{}: does not match pattern {}".format(location, schema["pattern"]))
        if schema.get("format") == "uuid":
            if re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}", instance) is None:
                errors.append("{}: invalid UUID".format(location))
        if schema.get("format") == "date-time":
            try:
                datetime.fromisoformat(instance.replace("Z", "+00:00"))
            except ValueError:
                errors.append("{}: invalid RFC 3339 date-time".format(location))

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append("{}: below minimum".format(location))
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append("{}: above maximum".format(location))

    return errors


def walk_refs(value, current_path, location="$"):
    if isinstance(value, dict):
        if "$ref" in value:
            target, _ = resolve_ref(value["$ref"], current_path)
            if target is None:
                fail("{} {}: unresolved $ref {}".format(current_path.name, location, value["$ref"]))
        for key, child in value.items():
            walk_refs(child, current_path, location + "." + key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk_refs(child, current_path, "{}[{}]".format(location, index))


def parse_openapi():
    ruby = (
        'require "yaml"; require "json"; '
        'puts JSON.generate(YAML.load_file(ARGV.fetch(0)))'
    )
    try:
        result = subprocess.run(
            ["ruby", "-e", ruby, str(OPENAPI_PATH)],
            check=True,
            capture_output=True,
            text=True,
        )
        document = json.loads(result.stdout)
    except Exception as exc:
        fail("openapi.yaml: YAML parse failed: {}".format(exc))
        return None
    if document.get("openapi") != "3.1.0":
        fail("openapi.yaml: expected OpenAPI 3.1.0")
    return document


def validate_openapi_links(document):
    def visit(value, location="$"):
        if isinstance(value, dict):
            ref = value.get("$ref")
            if ref:
                if ref.startswith("#"):
                    json_pointer(document, ref[1:], "openapi.yaml " + location)
                else:
                    target, _ = resolve_ref(ref, OPENAPI_PATH)
                    if target is None:
                        fail("openapi.yaml {}: unresolved {}".format(location, ref))
            external = value.get("externalValue")
            if external:
                target = (OPENAPI_PATH.parent / external).resolve()
                if not target.is_file():
                    fail("openapi.yaml {}: missing externalValue {}".format(location, external))
            for key, child in value.items():
                visit(child, location + "." + key)
        elif isinstance(value, list):
            for index, child in enumerate(value):
                visit(child, "{}[{}]".format(location, index))

    visit(document)


INVALID_FILENAME_CHARACTERS = set('<>:"/\\|?*')
RESERVED_STEMS = {"CON", "PRN", "AUX", "NUL"}
RESERVED_STEMS.update("COM{}".format(index) for index in range(1, 10))
RESERVED_STEMS.update("LPT{}".format(index) for index in range(1, 10))


def sanitize_filename(value):
    value = unicodedata.normalize("NFC", value)
    value = "".join(
        "_" if ord(character) <= 0x1F or character in INVALID_FILENAME_CHARACTERS else character
        for character in value
    )
    value = value.rstrip(" .")
    if value in ("", ".", ".."):
        value = "_"
    if value.split(".", 1)[0].upper() in RESERVED_STEMS:
        value = "_" + value
    return value


def utf16_units(value):
    return len(value.encode("utf-16-le")) // 2


def expand_expression(case, key):
    literal_key = "path" if key == "pathExpression" else "expectedPath"
    if literal_key in case:
        return case[literal_key]
    result = []
    for part in case[key]:
        if isinstance(part, str):
            result.append(part)
        else:
            result.append(part["repeat"] * part["count"])
    return "".join(result)


def validate_relative_path(path):
    if utf16_units(path) > 239:
        return False, "path_conflict"
    if not path or path.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", path) or "\\" in path:
        return False, "unsafe_path"
    segments = path.split("/")
    if any(not segment or segment in (".", "..") for segment in segments):
        return False, "unsafe_path"
    if any(segment != sanitize_filename(segment) for segment in segments):
        return False, "unsafe_path"
    return True, None


def split_extension(filename):
    index = filename.rfind(".")
    return (filename, "") if index <= 0 else (filename[:index], filename[index:])


def suffixed_path(path, file_id, force_suffix):
    if not force_suffix and utf16_units(path) <= 239:
        return path, None
    parent, separator, filename = path.rpartition("/")
    parent_prefix = parent + separator if separator else ""
    stem, extension = split_extension(filename)
    suffix = "~" + file_id.replace("-", "")[:8].lower()
    available = 239 - utf16_units(parent_prefix + suffix + extension)
    while stem and utf16_units(stem) > available:
        stem = stem[:-1]
    if not stem or available < 1:
        return None, "path_conflict"
    return parent_prefix + stem + suffix + extension, None


def validate_path_vectors(vectors):
    for case in vectors["sanitizeFilename"]:
        actual = sanitize_filename(case["input"])
        if actual != case["expected"]:
            fail("path vector {}: got {!r}, expected {!r}".format(case["id"], actual, case["expected"]))

    for case in vectors["validateRelativePath"]:
        path = expand_expression(case, "pathExpression")
        valid, error = validate_relative_path(path)
        if valid != case["valid"] or error != case.get("error"):
            fail("path vector {}: got valid={} error={}".format(case["id"], valid, error))

    for case in vectors["shortenRelativePath"]:
        path = expand_expression(case, "pathExpression")
        actual, error = suffixed_path(path, case["fileId"], False)
        if "error" in case:
            if error != case["error"]:
                fail("path vector {}: got error {}".format(case["id"], error))
        else:
            expected = expand_expression(case, "expectedPathExpression")
            if actual != expected or error is not None:
                fail("path vector {}: shortening mismatch".format(case["id"]))

    for case in vectors["resolveCaseInsensitiveCollision"]:
        proposed = case["proposedPath"]
        existing = {path.casefold() for path in case["existingPaths"]}
        if proposed.casefold() not in existing:
            actual, error = proposed, None
        else:
            actual, error = suffixed_path(proposed, case["fileId"], True)
            if actual is not None and actual.casefold() in existing:
                actual, error = None, "path_conflict"
        if "error" in case:
            if error != case["error"]:
                fail("path vector {}: got error {}".format(case["id"], error))
        elif actual != case["expectedPath"] or error is not None:
            fail("path vector {}: collision result mismatch".format(case["id"]))


def validate_fixture_relationships():
    request = load_json(FIXTURE_ROOT / "create-job.request.json")
    response = load_json(FIXTURE_ROOT / "create-job.response.json")
    if not request or not response:
        return
    if request["selection"]["assetCount"] != len(request["assets"]):
        fail("create-job fixture: selection.assetCount does not match assets")
    asset_ids = {asset["assetId"] for asset in request["assets"]}
    file_ids = set()
    for asset in request["assets"]:
        for export_file in asset["files"]:
            if export_file["assetId"] != asset["assetId"]:
                fail("create-job fixture: file assetId does not match its parent")
            if export_file["fileId"] in file_ids:
                fail("create-job fixture: duplicate fileId")
            file_ids.add(export_file["fileId"])
    if any(membership["assetId"] not in asset_ids for membership in request["albumMemberships"]):
        fail("create-job fixture: membership references an unknown asset")
    decision_ids = {decision["fileId"] for decision in response["decisions"]}
    if decision_ids != file_ids:
        fail("create-job fixture: receiver decisions do not cover exactly the requested files")

    clean_complete = load_json(FIXTURE_ROOT / "complete-job.request.json")
    clean_report = load_json(FIXTURE_ROOT / "completion-report.response.json")
    if clean_complete is not None and clean_complete.get("failures", []) != []:
        fail("clean completion fixture: omitted failures must default to empty")
    if clean_report is not None:
        if clean_report["failures"] or clean_report["state"] != "completed":
            fail("clean completion fixture: empty failures must produce completed state")
        if clean_report["counts"]["filesFailed"] != 0:
            fail("clean completion fixture: filesFailed must be zero")

    failure_complete = load_json(FIXTURE_ROOT / "complete-job-with-failures.request.json")
    failure_report = load_json(FIXTURE_ROOT / "completion-report-with-failures.response.json")
    if failure_complete is None or failure_report is None:
        return
    submitted_failures = failure_complete.get("failures", [])
    submitted_ids = [item["fileId"] for item in submitted_failures]
    if len(submitted_ids) != len(set(submitted_ids)):
        fail("failure completion fixture: failure fileIds are not unique")
    pending_ids = {
        decision["fileId"]
        for decision in response["decisions"]
        if decision["action"] in ("upload", "resume", "conflict")
    }
    if any(file_id not in pending_ids for file_id in submitted_ids):
        fail("failure completion fixture: failure does not reference a pending job file")
    if failure_report["failures"] != submitted_failures:
        fail("failure completion fixture: report does not preserve submitted failures")
    if failure_report["state"] != "completedWithFailures":
        fail("failure completion fixture: nonempty failures require completedWithFailures")
    if failure_report["counts"]["filesFailed"] != len(failure_report["failures"]):
        fail("failure completion fixture: filesFailed does not match report failures")


def main():
    schema_paths = sorted(SCHEMA_ROOT.glob("*.json"))
    fixture_paths = sorted(FIXTURE_ROOT.glob("*.json"))
    for path in schema_paths + fixture_paths + [VECTOR_PATH]:
        load_json(path)

    for path in schema_paths:
        document = load_json(path)
        if document is not None:
            walk_refs(document, path)

    fixture_map = load_json(FIXTURE_ROOT / "_fixture-map.json") or {}
    mapped_files = set(fixture_map)
    actual_files = {path.name for path in fixture_paths if path.name != "_fixture-map.json"}
    if mapped_files != actual_files:
        fail("fixture map mismatch: mapped={} actual={}".format(sorted(mapped_files), sorted(actual_files)))
    for fixture_name, schema_ref in fixture_map.items():
        fixture = load_json(FIXTURE_ROOT / fixture_name)
        schema_name, _, fragment = schema_ref.partition("#")
        schema_path = SCHEMA_ROOT / schema_name
        schema_document = load_json(schema_path)
        schema = json_pointer(schema_document, fragment, schema_ref) if schema_document is not None else None
        if fixture is not None and schema is not None:
            for error in schema_errors(fixture, schema, schema_path):
                fail("{} against {}: {}".format(fixture_name, schema_ref, error))

    openapi = parse_openapi()
    if openapi is not None:
        validate_openapi_links(openapi)

    vectors = load_json(VECTOR_PATH)
    if vectors is not None:
        validate_path_vectors(vectors)
    validate_fixture_relationships()

    if ERRORS:
        for error in ERRORS:
            print("ERROR: " + error, file=sys.stderr)
        print("Validation failed with {} error(s).".format(len(ERRORS)), file=sys.stderr)
        return 1
    print(
        "Validated {} schemas, {} fixtures, OpenAPI links, and {} path vectors.".format(
            len(schema_paths),
            len(actual_files),
            sum(len(vectors[key]) for key in (
                "sanitizeFilename",
                "validateRelativePath",
                "shortenRelativePath",
                "resolveCaseInsensitiveCollision",
            )),
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
