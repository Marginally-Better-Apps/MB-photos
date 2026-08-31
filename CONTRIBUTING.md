# Contributing

## Safety first

This project handles irreplaceable user media. Changes to transfer, hashing, path resolution, resource classification, or ledger state must include tests for interruption and failure as well as the happy path.

The MVP has two non-negotiable invariants:

1. The iOS application never submits a PhotoKit mutation request.
2. The receiver never deletes or overwrites a committed destination file as an implicit consequence of source state.

## Before opening a pull request

- Run the protocol schema and fixture validation.
- Run the iOS unit tests and a generic-device build.
- Run the Windows core and integration test projects on Windows with .NET 10.
- Add matching Swift and C# cases when changing a shared protocol field, path rule, hash rule, or error code.
- Do not commit signing material, generated backup contents, Photo Library identifiers, receiver tokens, or unredacted diagnostics.

Physical-device transfer behavior cannot be established by simulator tests alone. Changes affecting PhotoKit originals, iCloud retrieval, camera pairing, local-network privacy, TLS pinning, interruption, or large media should include the device/Windows versions and test scenario in the pull request.

## Compatibility

Protocol changes are additive within major version 1. A required or behavior-changing field requires a new protocol major version unless both released clients can safely ignore it. Database changes use migrations and must preserve resumable jobs and committed-file receipts.
