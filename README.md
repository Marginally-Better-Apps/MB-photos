# MB Photos

MB Photos is a local, additive photo-library system for iPhone and Windows. The iOS app reads Apple Photos and sends exact PhotoKit resources over the local network to a small Windows receiver. The receiver builds a portable, date-organized `Master` folder containing one current full-quality photo or video per synced asset, while retaining originals and Live Photo motion in separate library data. A file is accepted only after SHA-256 verification.

The iOS app can stage review decisions and, only after an explicit final confirmation, ask Apple Photos to move selected items into its Recently Deleted collection. The Windows receiver remains additive and never mirrors source deletions.

## Repository layout

- `ios/` — SwiftUI iOS 18+ exporter, PhotoKit integration, export planner, transfer client, and tests.
- `windows/` — .NET 10 WPF receiver, resumable storage engine, SQLite ledger, local HTTPS API, and tests.
- `protocol/` — versioned protocol schemas, endpoint contracts, shared fixtures, and cross-platform path test vectors.
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
4. Review the exact current Master representations and supporting archive resources selected for transfer.
5. Explicitly start the export. On iOS 26+ the system can continue that verified, user-started work after backgrounding; on older releases it checkpoints and pauses safely when its finite background time ends.
6. The Windows receiver remains available from the system tray after its window closes. If either process stops, pair again and resume from the last acknowledged 8 MiB chunk.
7. Review the receiver-generated JSON report. Only files committed after matching sender and receiver SHA-256 hashes are marked verified.

The selected Windows directory is additive. `Master/` contains media only and can be copied independently. `MB Photos Data/` contains originals needed for revert/export, Live Photo motion, portable catalogs, thumbnails, reports, and resumable receiver state. Moving the complete library root preserves all relationships because catalog paths are relative.

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
- Exact PhotoKit resources are never rewritten. Master and archive resources retain their embedded metadata, including location.
- There is no telemetry or cloud service. Diagnostic export is explicit and redacts photo names, albums, locations, and credentials.

See [SECURITY.md](SECURITY.md) and [PRIVACY.md](PRIVACY.md) for reporting and data-handling details.

## Current non-goals

The current release does not implement automatic deletion, editable filename templates, video transcoding, rendered Live Photo effects, USB/SMB/browser transfer, a Windows photo editor, a Windows service or autostart, Windows ARM64, macOS transfer, XMP sidecars, cloud storage, or automatic updates.
