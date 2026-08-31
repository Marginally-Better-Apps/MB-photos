# MB Photos local-transfer protocol v1

This directory is the language-neutral contract between the iOS exporter and the Windows receiver. Protocol v1 is intentionally local-only: the receiver binds to one private IPv4 interface, advertises a short-lived QR payload, and stops listening when its process exits.

## Contract files

- `openapi.yaml` describes every HTTPS operation and wire header.
- `schemas/v1/models.schema.json` defines persistent and shared domain models.
- `schemas/v1/api.schema.json` defines every JSON request and response envelope.
- `fixtures/v1/` contains a complete example exchange for a Live Photo plus a converted HEIC still.
- `test-vectors/windows-paths.json` is the normative cross-language suite for filename sanitization, path validation, shortening, and collision handling.

Schemas use JSON Schema 2020-12. JSON property names are camelCase. UUIDs are transmitted in canonical hyphenated form, timestamps are RFC 3339 UTC strings, SHA-256 values are 64 lowercase hexadecimal characters, and byte counts are non-negative JSON integers.

## Pairing and authentication

The Windows receiver creates an ephemeral self-signed TLS certificate, a cryptographically random 32-byte pairing token, and this QR URI:

```text
mbphotos://pair?v=1&host={private-ipv4}&port={port}&token={base64url-no-padding}&cert={lowercase-sha256-of-leaf-DER}
```

Query values must be percent encoded. The iOS client must reject non-private IPv4 hosts, pin the SHA-256 fingerprint of the leaf certificate before sending the pairing token, and never fall back to an unpinned or plaintext connection.

The token expires five minutes after creation and is consumed by the first successful `POST /v1/pair`. Pairing returns a random 32-byte bearer session token. That session remains valid only until the receiver exits. A consumed, expired, or unknown pairing token is rejected; if the pairing response is lost, the user starts a new receiver session and scans a new QR code.

All other endpoints require `Authorization: Bearer {sessionToken}`. Tokens must never appear in logs, reports, manifests, URLs, or error messages. Authentication and pairing responses use `Cache-Control: no-store`.

## Transfer sequence

1. Pair and inspect receiver capabilities.
2. Submit one frozen `ExportJob` with client-stable job, asset, and file UUIDs. When location retention is enabled, `ExportAsset.location` carries decimal WGS 84 latitude/longitude and optional altitude in meters; otherwise it is omitted.
3. Honor the receiver's `FileDecision` for every file. The receiver may sanitize or suffix a proposed path; only `acceptedRelativePath` is authoritative.
4. For `upload` or `resume`, send sequential chunks beginning at `nextChunkIndex`.
5. Commit each file with its exact byte count and whole-file SHA-256.
6. Complete the job to atomically write manifests and its completion report. The client may include failures for remaining source-unavailable or irreconcilably conflicted files.
7. On a user-requested discard, abandon the job. Abandonment deletes only uncommitted partial data.

`GET /v1/jobs/{jobId}` is the reconciliation operation after either app restarts. Committed files and acknowledged chunk ranges in its response supersede cached client progress.

`location` is optional and its absence means unavailable or intentionally withheld; zero latitude/longitude is not a sentinel. When `profile.preserveLocation` is false, the exporter must omit `ExportAsset.location` and remove location from generated JPEGs and manifests. Preserve Originals never rewrites embedded metadata in exact original resources.

## Chunk and digest rules

- The negotiated v1 chunk size is exactly 8,388,608 bytes. Every non-final chunk has this size; the final chunk may be shorter. A zero-byte file has no chunks and proceeds directly to commit.
- `Content-Range` uses inclusive end offsets: `bytes {start}-{end}/{wholeFileBytes}`. `start` must equal `chunkIndex * chunkSizeBytes`.
- `X-Chunk-SHA256` is the lowercase SHA-256 hex digest of the HTTP request body only.
- The receiver writes chunks under `.mbphotos/partial/{jobId}`, flushes data before acknowledging it, and transactionally persists its contiguous receipt range.
- Chunks are sequential. A future index returns `chunk_out_of_order`; an already acknowledged index with identical range, length, and digest returns the original receipt; an acknowledged index with different metadata returns `chunk_conflict`.
- Commit hashes the exact staged bytes. A successful commit flushes the file, compares byte count and SHA-256, atomically moves it to the accepted path, sets supported capture timestamps, and updates the destination ledger in one recoverable transaction.
- Hash mismatch never replaces a destination file. It leaves the job retryable and reports `hash_mismatch`.

## Idempotency and conflicts

No separate idempotency key is required because identifiers are client-generated and stable:

- Repeating `POST /v1/jobs` with the same `jobId` and semantically identical manifest returns the existing plan. Reusing the ID for a different manifest returns `job_conflict`.
- Chunk retry behavior is defined above.
- Repeating file commit with the same byte count and digest returns the existing commit receipt. Different commit metadata returns `file_conflict`.
- Repeating completion returns the stored report. Repeating abandonment returns the stored abandonment receipt.
- Pairing is intentionally not idempotent because its credential is single use.

An existing ledger record may be skipped only when source revision, accepted path, expected size, and destination metadata agree. If destination size or modification time changed outside the receiver, the receiver re-hashes it before returning `skip`. The receiver never overwrites an unrelated existing file; it either returns a deterministic suffixed accepted path or a `path_conflict` error.

### Terminal failures during completion

`CompleteJobRequest.failures` is optional and defaults to an empty array. It lets the client deliberately finish a job when a PhotoKit resource became unavailable or a file conflict could not be resolved:

- Every failure must have a unique `fileId`, and that ID must belong to this job and still be pending. Duplicate IDs return `invalid_request`, an unknown ID returns `file_not_found`, and a file already committed, skipped, or failed returns `file_conflict`.
- Completion is rejected with `file_conflict` while any planned file remains pending and is not named in the request.
- In one receiver database transaction, supplied pending files become failed, counts are finalized, manifests/report records are written, and the job becomes terminal. Internal partial bytes for newly failed files are removed after that durable transition and are cleaned up during recovery if deletion is interrupted.
- A report with at least one failed file has state `completedWithFailures`; otherwise it has state `completed`. `counts.filesFailed` equals the number of report failures.
- An exact retry after completion returns the stored report before pending-state checks. Reusing the completed `jobId` with different completion failures returns `job_conflict`.

## Windows path policy v1

Both apps run the normative vectors, but the Windows receiver is the security boundary and revalidates every path.

Filename sanitization:

1. Normalize to Unicode NFC.
2. Replace each control character `U+0000...U+001F` and each of `< > : " / \\ | ? *` with `_` (one replacement per code point; do not collapse runs).
3. Remove trailing ASCII spaces and periods.
4. If the result is empty, `.` or `..`, use `_`.
5. If the portion before the first period case-insensitively equals `CON`, `PRN`, `AUX`, `NUL`, `COM1` through `COM9`, or `LPT1` through `LPT9`, prefix the filename with `_`.

Relative-path validation rejects absolute, rooted, UNC, device-namespace, drive-qualified, empty-segment, `.`-segment, and `..`-segment paths. It also rejects any segment that is not already equal to its sanitized form. The canonical full path must remain beneath the chosen backup root under Windows ordinal-ignore-case comparison and the relative path must contain at most 239 UTF-16 code units.

When a planned path is too long, shorten only the final filename. Preserve its final extension (including the period), append `~{firstEightFileIdHexWithoutHyphens}` to the shortened stem, and remove Unicode scalars from the end of the stem until the relative path is at most 239 UTF-16 units. The stem must retain at least one scalar; otherwise return `path_conflict`. Use the same suffix before the extension for a case-insensitive collision. Do not silently overwrite.

## Errors and HTTP mapping

Every non-2xx JSON response is an `ApiError` with a stable `code`, a safe user-facing `message`, and `retryable`. `requestId` is diagnostic correlation only.

| HTTP | Codes |
| --- | --- |
| 400 | `invalid_request`, `unsafe_path`, `chunk_out_of_order` |
| 401 | `authentication_required`, `authentication_invalid` |
| 404 | `job_not_found`, `file_not_found` |
| 409 | `token_consumed`, `job_conflict`, `file_conflict`, `chunk_conflict`, `path_conflict`, `changed_destination` |
| 410 | `token_expired` |
| 422 | `hash_mismatch`, `unavailable_source` |
| 426 | `protocol_mismatch` |
| 507 | `disk_full` |
| 500/503 | `internal_error`, `network_loss` |

Clients branch on `code`, never on `message`. `network_loss` normally originates locally rather than as an HTTP response, but is included so both ledgers and completion reports use the same vocabulary. Unknown future error codes must be shown generically and treated according to `retryable`.

## Versioning and validation

Protocol v1 additions may introduce optional JSON properties or new error codes. Removing a property, making an optional property required, changing path/hash behavior, or adding an enum value to a behavior-controlling field requires a new protocol version. Receivers reject unsupported versions with `protocol_mismatch` before creating a job.

From the repository root, basic syntax and fixture validation can be run with:

```sh
python3 -m json.tool protocol/schemas/v1/models.schema.json >/dev/null
python3 -m json.tool protocol/schemas/v1/api.schema.json >/dev/null
python3 -m json.tool protocol/test-vectors/windows-paths.json >/dev/null
ruby -e 'require "yaml"; YAML.load_file("protocol/openapi.yaml")'
```

Swift and .NET test targets should additionally validate every fixture against the named schema in each fixture's companion `_fixture-map.json` and execute every path-policy vector.
