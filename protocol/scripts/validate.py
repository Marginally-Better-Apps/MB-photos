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
VERSIONS = ("v1", "v2")
SCHEMA_ROOTS = {version: PROTOCOL_ROOT / "schemas" / version for version in VERSIONS}
FIXTURE_ROOTS = {version: PROTOCOL_ROOT / "fixtures" / version for version in VERSIONS}
VECTOR_PATH = PROTOCOL_ROOT / "test-vectors" / "windows-paths.json"
OPENAPI_PATHS = (PROTOCOL_ROOT / "openapi.yaml", PROTOCOL_ROOT / "openapi-v2.yaml")

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


def parse_openapi(openapi_path):
    ruby = (
        'require "yaml"; require "json"; '
        'puts JSON.generate(YAML.load_file(ARGV.fetch(0)))'
    )
    try:
        result = subprocess.run(
            ["ruby", "-e", ruby, str(openapi_path)],
            check=True,
            capture_output=True,
            text=True,
        )
        document = json.loads(result.stdout)
    except Exception as exc:
        fail("{}: YAML parse failed: {}".format(openapi_path.name, exc))
        return None
    if document.get("openapi") != "3.1.0":
        fail("{}: expected OpenAPI 3.1.0".format(openapi_path.name))
    return document


def validate_openapi_links(document, openapi_path):
    def visit(value, location="$"):
        if isinstance(value, dict):
            ref = value.get("$ref")
            if ref:
                if ref.startswith("#"):
                    json_pointer(document, ref[1:], openapi_path.name + " " + location)
                else:
                    target, _ = resolve_ref(ref, openapi_path)
                    if target is None:
                        fail("{} {}: unresolved {}".format(openapi_path.name, location, ref))
            external = value.get("externalValue")
            if external:
                target = (openapi_path.parent / external).resolve()
                if not target.is_file():
                    fail("{} {}: missing externalValue {}".format(openapi_path.name, location, external))
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


def validate_completion_fixtures(fixture_root, response):
    version = fixture_root.name
    clean_complete = load_json(fixture_root / "complete-job.request.json")
    clean_report = load_json(fixture_root / "completion-report.response.json")
    if clean_complete is not None and clean_complete.get("failures", []) != []:
        fail("{} clean completion fixture: omitted failures must default to empty".format(version))
    if clean_report is not None:
        if clean_report["failures"] or clean_report["state"] != "completed":
            fail("{} clean completion fixture: empty failures must produce completed state".format(version))
        if clean_report["counts"]["filesFailed"] != 0:
            fail("{} clean completion fixture: filesFailed must be zero".format(version))

    failure_complete = load_json(fixture_root / "complete-job-with-failures.request.json")
    failure_report = load_json(fixture_root / "completion-report-with-failures.response.json")
    if failure_complete is None or failure_report is None:
        return
    submitted_failures = failure_complete.get("failures", [])
    submitted_ids = [item["fileId"] for item in submitted_failures]
    if len(submitted_ids) != len(set(submitted_ids)):
        fail("{} failure completion fixture: failure fileIds are not unique".format(version))
    pending_ids = {
        decision["fileId"]
        for decision in response["decisions"]
        if decision["action"] in ("upload", "resume", "conflict")
    }
    if any(file_id not in pending_ids for file_id in submitted_ids):
        fail("{} failure completion fixture: failure does not reference a pending job file".format(version))
    if failure_report["failures"] != submitted_failures:
        fail("{} failure completion fixture: report does not preserve submitted failures".format(version))
    if failure_report["state"] != "completedWithFailures":
        fail("{} failure completion fixture: nonempty failures require completedWithFailures".format(version))
    if failure_report["counts"]["filesFailed"] != len(failure_report["failures"]):
        fail("{} failure completion fixture: filesFailed does not match report failures".format(version))


def validate_v1_fixture_relationships():
    fixture_root = FIXTURE_ROOTS["v1"]
    request = load_json(fixture_root / "create-job.request.json")
    response = load_json(fixture_root / "create-job.response.json")
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

    validate_completion_fixtures(fixture_root, response)


def validate_v2_asset(asset, label, catalog=False):
    path_key = "acceptedRelativePath" if catalog else "proposedRelativePath"
    files = asset["files"]
    file_ids = [item["fileId"] for item in files]
    if len(file_ids) != len(set(file_ids)):
        fail("{}: duplicate fileId".format(label))
    file_map = {item["fileId"]: item for item in files}

    for item in files:
        if not catalog and item["assetId"] != asset["assetId"]:
            fail("{}: file {} assetId does not match its parent".format(label, item["fileId"]))
        path = item[path_key]
        if path is not None:
            valid, error = validate_relative_path(path)
            if not valid:
                fail("{}: file {} has invalid path ({})".format(label, item["fileId"], error))

        roles = set(item["roles"])
        if item["storageArea"] == "master":
            if path is not None and not path.startswith("Master/"):
                fail("{}: master file {} is outside Master/".format(label, item["fileId"]))
            if "masterCurrent" not in roles:
                fail("{}: master file {} lacks masterCurrent role".format(label, item["fileId"]))
            if roles - {"masterCurrent", "rootOriginal"}:
                fail("{}: master file {} contains a support-only role".format(label, item["fileId"]))
        else:
            if path is not None and not path.startswith("MB Photos Data/"):
                fail("{}: library-data file {} is outside MB Photos Data/".format(label, item["fileId"]))
            if "masterCurrent" in roles:
                fail("{}: masterCurrent file {} is not in Master/".format(label, item["fileId"]))

        if roles.intersection({"currentLiveMotion", "originalLiveMotion"}) and item["storageArea"] != "libraryData":
            fail("{}: Live Photo motion file {} must be libraryData".format(label, item["fileId"]))
        if item["criticality"] == "masterRequired" and "masterCurrent" not in roles:
            fail("{}: masterRequired file {} lacks masterCurrent role".format(label, item["fileId"]))
        if item["provenance"] == "generatedThumbnail":
            if item["photoKitResourceType"] is not None or item["photoKitResourceTypeRaw"] is not None:
                fail("{}: generated thumbnail {} has a PhotoKit resource type".format(label, item["fileId"]))
            if item["storageArea"] != "libraryData" or item["criticality"] != "optional" or roles != {"auxiliary"}:
                fail("{}: generated thumbnail {} must be optional libraryData auxiliary".format(label, item["fileId"]))
            if not catalog:
                expected_thumbnail_path = "MB Photos Data/Thumbnails/{}/{}.jpg".format(
                    asset["assetId"].lower(), item["fileId"].lower()
                )
                if path != expected_thumbnail_path:
                    fail("{}: generated thumbnail {} does not use its canonical proposed path".format(
                        label, item["fileId"]
                    ))
        elif item["photoKitResourceType"] is None or item["photoKitResourceTypeRaw"] is None:
            fail("{}: exact PhotoKit file {} lacks its type/raw code".format(label, item["fileId"]))

        if item["availability"] != "available" and item["sha256"] is not None:
            fail("{}: unavailable file {} must not claim a verified digest".format(label, item["fileId"]))
        if catalog and item["availability"] == "available":
            if item["byteCount"] is None or item["sha256"] is None or path is None:
                fail("{}: available catalog file {} lacks bytes, digest, or path".format(label, item["fileId"]))

    available_master_ids = {
        item["fileId"]
        for item in files
        if "masterCurrent" in item["roles"] and item["availability"] == "available"
    }
    master_file_id = asset["masterFileId"]
    if master_file_id is None:
        if available_master_ids:
            fail("{}: null masterFileId conflicts with an available master".format(label))
    elif master_file_id not in available_master_ids:
        fail("{}: masterFileId does not reference an available masterCurrent file".format(label))
    if len(available_master_ids) > 1:
        fail("{}: more than one available masterCurrent file".format(label))

    relationships = asset["livePhotoRelationships"]
    is_live = "livePhoto" in asset["mediaSubtypes"]
    if is_live != (relationships is not None):
        fail("{}: livePhoto subtype and livePhotoRelationships disagree".format(label))
    if relationships is not None:
        role_by_relationship = {
            "currentStillFileId": "masterCurrent",
            "currentMotionFileId": "currentLiveMotion",
            "originalStillFileId": "rootOriginal",
            "originalMotionFileId": "originalLiveMotion",
        }
        for field, required_role in role_by_relationship.items():
            referenced_id = relationships[field]
            if referenced_id is None:
                continue
            referenced = file_map.get(referenced_id)
            if referenced is None:
                fail("{}: {} references an unknown file".format(label, field))
            elif required_role not in referenced["roles"]:
                fail("{}: {} file lacks {} role".format(label, field, required_role))
        if master_file_id is not None and relationships["currentStillFileId"] != master_file_id:
            fail("{}: current Live still is not the active master".format(label))

    if catalog:
        archive_incomplete = any(
            item["criticality"] == "archiveRequired" and item["availability"] != "available"
            for item in files
        )
        expected_state = "incomplete" if archive_incomplete else "complete"
        if asset["archiveState"] != expected_state:
            fail("{}: archiveState must be {}".format(label, expected_state))


def validate_v2_job(request, label):
    if request["selection"]["assetCount"] != len(request["assets"]):
        fail("{}: selection.assetCount does not match assets".format(label))
    asset_ids = [asset["assetId"] for asset in request["assets"]]
    if len(asset_ids) != len(set(asset_ids)):
        fail("{}: duplicate assetId".format(label))
    all_file_ids = []
    for index, asset in enumerate(request["assets"]):
        validate_v2_asset(asset, "{} assets[{}]".format(label, index))
        all_file_ids.extend(item["fileId"] for item in asset["files"])
    if len(all_file_ids) != len(set(all_file_ids)):
        fail("{}: fileId is reused across assets".format(label))
    known_assets = set(asset_ids)
    if any(membership["assetId"] not in known_assets for membership in request["albumMemberships"]):
        fail("{}: album membership references an unknown asset".format(label))
    return set(all_file_ids)


def validate_v2_fixture_relationships():
    fixture_root = FIXTURE_ROOTS["v2"]
    request = load_json(fixture_root / "create-job.request.json")
    response = load_json(fixture_root / "create-job.response.json")
    if not request or not response:
        return
    file_ids = validate_v2_job(request, "v2 create-job fixture")
    decision_ids = [decision["fileId"] for decision in response["decisions"]]
    if len(decision_ids) != len(set(decision_ids)) or set(decision_ids) != file_ids:
        fail("v2 create-job fixture: receiver decisions do not cover exactly the requested files")
    for decision in response["decisions"]:
        accepted = decision["acceptedRelativePath"]
        if accepted is not None and not validate_relative_path(accepted)[0]:
            fail("v2 create-job fixture: decision has an invalid acceptedRelativePath")

    scenario = load_json(fixture_root / "scenario-matrix.request.json")
    if scenario:
        validate_v2_job(scenario, "v2 scenario matrix")
        scenario_subtypes = {
            subtype
            for asset in scenario["assets"]
            for subtype in asset["mediaSubtypes"]
        }
        required_subtype_vectors = {"screenRecording", "spatialMedia"}
        if not required_subtype_vectors.issubset(scenario_subtypes):
            fail("v2 scenario matrix: missing screenRecording/spatialMedia subtype vectors")

    catalog_asset = load_json(fixture_root / "catalog-asset.json")
    if catalog_asset:
        validate_v2_asset(catalog_asset, "v2 catalog asset", catalog=True)
    pointer = load_json(fixture_root / "catalog-current.json")
    if pointer:
        generation = pointer["generationId"]
        if "/{}/".format(generation) not in pointer["assetsRelativePath"]:
            fail("v2 catalog pointer: assets path does not contain generationId")
        if "/{}/".format(generation) not in pointer["albumsRelativePath"]:
            fail("v2 catalog pointer: albums path does not contain generationId")
    validate_completion_fixtures(fixture_root, response)


def validate_v2_job_asset_limit():
    schema_path = SCHEMA_ROOTS["v2"] / "models.schema.json"
    schema = load_json(schema_path)
    if not schema:
        return
    assets_schema = schema["$defs"]["ExportJob"]["properties"]["assets"]
    if assets_schema.get("maxItems") != 100_000:
        fail("v2 ExportJob.assets must cap one job at 100,000 assets")
        return
    boundary_schema = {
        key: assets_schema[key]
        for key in ("type", "minItems", "maxItems")
    }
    if schema_errors([None] * 100_000, boundary_schema, schema_path):
        fail("v2 ExportJob.assets rejected the 100,000-asset boundary")
    if not schema_errors([None] * 100_001, boundary_schema, schema_path):
        fail("v2 ExportJob.assets accepted a 100,001-asset job")


def main():
    schema_paths = []
    fixture_paths = []
    for version in VERSIONS:
        schema_paths.extend(sorted(SCHEMA_ROOTS[version].glob("*.json")))
        fixture_paths.extend(sorted(FIXTURE_ROOTS[version].glob("*.json")))
    for path in schema_paths + fixture_paths + [VECTOR_PATH]:
        load_json(path)

    for path in schema_paths:
        document = load_json(path)
        if document is not None:
            walk_refs(document, path)

    actual_fixture_count = 0
    for version in VERSIONS:
        fixture_root = FIXTURE_ROOTS[version]
        schema_root = SCHEMA_ROOTS[version]
        version_fixture_paths = sorted(fixture_root.glob("*.json"))
        fixture_map = load_json(fixture_root / "_fixture-map.json") or {}
        mapped_files = set(fixture_map)
        actual_files = {path.name for path in version_fixture_paths if path.name != "_fixture-map.json"}
        actual_fixture_count += len(actual_files)
        if mapped_files != actual_files:
            fail("{} fixture map mismatch: mapped={} actual={}".format(
                version, sorted(mapped_files), sorted(actual_files)
            ))
        for fixture_name, schema_ref in fixture_map.items():
            fixture = load_json(fixture_root / fixture_name)
            schema_name, _, fragment = schema_ref.partition("#")
            schema_path = schema_root / schema_name
            schema_document = load_json(schema_path)
            schema = json_pointer(schema_document, fragment, schema_ref) if schema_document is not None else None
            if fixture is not None and schema is not None:
                for error in schema_errors(fixture, schema, schema_path):
                    fail("{}/{} against {}: {}".format(version, fixture_name, schema_ref, error))

    for openapi_path in OPENAPI_PATHS:
        openapi = parse_openapi(openapi_path)
        if openapi is not None:
            validate_openapi_links(openapi, openapi_path)

    vectors = load_json(VECTOR_PATH)
    if vectors is not None:
        validate_path_vectors(vectors)
    validate_v1_fixture_relationships()
    validate_v2_fixture_relationships()
    validate_v2_job_asset_limit()

    if ERRORS:
        for error in ERRORS:
            print("ERROR: " + error, file=sys.stderr)
        print("Validation failed with {} error(s).".format(len(ERRORS)), file=sys.stderr)
        return 1
    print(
        "Validated {} schemas, {} fixtures, {} OpenAPI documents, and {} path vectors.".format(
            len(schema_paths),
            actual_fixture_count,
            len(OPENAPI_PATHS),
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
