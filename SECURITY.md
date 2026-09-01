# Security Policy

## Supported versions

Only the newest public-beta build is supported during the MVP period. Protocol compatibility is explicit: portable-library clients and receivers must agree on protocol major version 2 before creating a job. Legacy v1 destinations are rejected without modification.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose photo contents, pairing credentials, destination files, or arbitrary filesystem access. Report it privately to the repository maintainers with:

- affected app and version;
- reproduction steps;
- expected and observed behavior;
- whether the issue requires local-network access or an already paired session; and
- a minimal diagnostic log with personal photo data removed.

## Security invariants

- A pairing token is random, single-use, and expires after five minutes.
- A session ends when the receiver process exits.
- The iOS client validates the receiver certificate fingerprint from the QR payload.
- Receiver writes are constrained to the selected destination root.
- A file is not promoted into Master or library resources until its byte count and SHA-256 match the sender declaration.
- Retrying a chunk or commit is idempotent.
- An externally changed Master file is never overwritten or moved automatically.
- Abandoning a job deletes partial transfer data only; active Master files and verified archive resources are retained.
- Secrets, filenames, albums, and location metadata are excluded from routine logs.
