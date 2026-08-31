# MB Photos

MB Photos is a local, additive photo-export system for iPhone and Windows. The iOS app reads Apple Photos, prepares exact original resources and optional Windows-friendly JPEG renditions, and sends them over the local network to a small Windows receiver. The receiver writes a portable date-organized backup and considers a file complete only after SHA-256 verification.

The iOS app can stage review decisions and, only after an explicit final confirmation, ask Apple Photos to move selected items into its Recently Deleted collection. The Windows receiver remains additive and never mirrors source deletions.

## Repository layout

- `ios/` — SwiftUI iOS 18+ exporter, PhotoKit integration, export planner, transfer client, and tests.
- `windows/` — .NET 10 WPF receiver, resumable storage engine, SQLite ledger, local HTTPS API, and tests.
- `protocol/` — protocol-v1 schemas, endpoint contract, shared fixtures, and cross-platform path test vectors.
- `plan.md` — broader product direction beyond this export-focused MVP.

## Core workflows

### Organize and review

1. Open Organize to see a breakdown of the accessible library and deterministic review suggestions.
2. Browse or start a review session. Use the card buttons to keep an item, revisit it later, or add it to the app-level Recently Deleted queue.
3. Review the complete queue before submitting it to Apple Photos.
4. Confirm the system PhotoKit prompt. Apple Photos moves confirmed items to Recently Deleted; only the user can restore or permanently clear them there.
5. Use Deleted Items for the app’s permanent audit history. It is not a live view of Apple Photos’ inaccessible Recently Deleted collection; an interrupted confirmation is labeled Result Not Recorded rather than assumed successful.

### Verified Windows export

1. Start the Windows receiver and select a backup directory.
2. Scan its one-time QR code from the iOS app while both devices are on the same Wi-Fi network.
3. Select all assets, new/changed assets, a date range, albums, or individual assets.
4. Choose exact originals or originals plus current Windows-compatible JPEGs.
5. Review preflight information and explicitly start the export. On iOS 26+ the system can continue that verified, user-started work after backgrounding; on older releases it checkpoints and pauses safely when its finite background time ends.
6. The Windows receiver remains available from the system tray after its window closes. If either process stops, pair again and resume from the last acknowledged 8 MiB chunk.
7. Review the receiver-generated JSON report. Only files committed after matching sender and receiver SHA-256 hashes are marked verified.

The selected Windows directory is additive. Exported files live below `Photos/`; portable metadata and reports live below `Metadata/` and `Reports/`; resumable internal state lives below `.mbphotos/`.

## Development prerequisites

### iOS

- macOS with Xcode 26 or newer.
- An iOS 18+ deployment target.
- A physical iPhone for PhotoKit, camera/QR, local-network, iCloud-resource, and pinned-TLS end-to-end testing.

Open the generated Xcode project described in `ios/README.md`. Simulator and fixture-provider tests exercise planning and UI logic, but the release gates require a physical device.

### Windows

- Windows 10 22H2 or Windows 11 x64.
- .NET 10 SDK.
- A code-signing certificate for public artifacts.

Build and test commands are documented in `windows/README.md`. The receiver is published as a self-contained x64 executable and does not install a service.

## Security and privacy

- Transfer is local-only and uses a newly generated receiver certificate plus a one-time 256-bit pairing token.
- The iOS client pins the exact certificate fingerprint carried by the QR payload.
- The receiver canonicalizes every requested path and refuses absolute paths, traversal, reserved Windows names, and any result outside the chosen backup root.
- Exact originals are never rewritten. Location removal applies only to generated JPEGs and portable manifests.
- There is no telemetry or cloud service. Diagnostic export is explicit and redacts photo names, albums, locations, and credentials.

See [SECURITY.md](SECURITY.md) and [PRIVACY.md](PRIVACY.md) for reporting and data-handling details.

## Continuous integration

Pull requests validate the protocol contract, run iOS unit tests on a simulator, and run Windows core and integration tests on Windows with .NET 10. Release signing is intentionally separate and requires protected repository secrets.

## Current non-goals

The current release does not implement similarity or blur scoring, automatic deletion, tags, editable filename templates, video transcoding, USB/SMB/browser transfer, a Windows service or autostart, Windows ARM64, macOS transfer, XMP sidecars, cloud storage, or automatic updates.
