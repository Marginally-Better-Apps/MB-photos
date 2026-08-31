# MB Photos Windows Receiver

The receiver is a deliberately small companion to the iOS exporter. It listens while the app is running, including when its WPF window is hidden in the notification area, accepts one certificate-pinned session on a private IPv4 LAN, writes into a user-confirmed backup root, and never deletes committed files.

## Projects

- `src/MBPhotos.Receiver.Core` contains the protocol-v1 HTTPS host, pairing, SQLite ledger, path security, incremental planning, chunk transfer, verification, reports, and diagnostics. It targets .NET 10 in production and conditionally targets .NET 7 only when built by the older SDK installed on the repository's macOS host.
- `src/MBPhotos.Receiver.Wpf` is the .NET 10 Windows x64 UI and portable single-file publish target.
- `tests/MBPhotos.Receiver.Tests` is a dependency-free console test runner. It executes the shared protocol fixtures and every normative Windows path vector, then exercises the real SQLite/transfer implementation.

## Build and test

Production prerequisites are the .NET 10 SDK on Windows 10 22H2 or Windows 11:

```powershell
dotnet restore windows/MBPhotos.Windows.sln
dotnet build windows/MBPhotos.Windows.sln -c Release
dotnet run --project windows/tests/MBPhotos.Receiver.Tests/MBPhotos.Receiver.Tests.csproj -c Release --no-build
```

On the repository's current macOS .NET 7 fallback, build and run only the cross-platform target:

```sh
dotnet restore windows/tests/MBPhotos.Receiver.Tests/MBPhotos.Receiver.Tests.csproj
dotnet build windows/tests/MBPhotos.Receiver.Tests/MBPhotos.Receiver.Tests.csproj -c Release -f net7.0
dotnet run --project windows/tests/MBPhotos.Receiver.Tests/MBPhotos.Receiver.Tests.csproj -c Release -f net7.0 --no-build
```

WPF and the self-contained `win-x64` executable cannot be compiled or visually exercised on macOS. In a sandboxed macOS .NET 7 process, the live Kestrel test may also report a skip because Apple Crypto refuses to create a temporary private-key certificate; path, token, authorization, ledger, and transfer behavior remain covered independently.

## Publishing and signing

The application is configured as a self-contained, compressed, single-file `win-x64` publish. Run the signing script from a Windows SDK developer shell with a real code-signing certificate:

```powershell
./windows/scripts/publish-signed.ps1 -CertificateThumbprint YOUR_CERT_THUMBPRINT
```

The script publishes `MBPhotosReceiver.exe`, signs it with SHA-256 and an RFC 3161 timestamp, and verifies the Authenticode signature. No certificate or private key is stored in this repository.

## Receiver behavior

- Choosing an uninitialized folder requires the explicit initialization checkbox. Nonempty reserved `Metadata`, `Reports`, or `.mbphotos` paths are rejected and left untouched.
- Each process run creates a self-signed process-lifetime certificate, a 256-bit five-minute single-use pairing token, and a process-lifetime bearer session. Windows uses a temporary current-user key container because Schannel cannot serve TLS from an ephemeral private key; it is not persisted beyond certificate disposal. Tokens, filenames, album titles, and location values are redacted from diagnostics.
- Uploads use sequential 8 MiB chunks. Receipts, the first observed total for unknown-size outputs, and original receipt timestamps are durable in SQLite. Retrying an acknowledged chunk is idempotent.
- Each chunk and committed file is SHA-256 verified. Final files are moved atomically from `.mbphotos/partial/{jobId}`; a mismatch is quarantined until retry or abandonment.
- Crash reconciliation truncates bytes flushed without a ledger receipt and recognizes a hash-valid final file moved before its commit transaction.
- Existing or externally changed files are never overwritten. A single stable `~{fileId-prefix}` collision suffix is allowed; if that is occupied the receiver returns `path_conflict`.
- All output paths are revalidated at the Windows security boundary. Rooted/traversal/device paths and any existing symbolic-link or junction ancestor are rejected.
- A changed PhotoKit identifier is never heuristically associated in v1. Without stable IDs, the safe fallback is a full upload to a non-overwriting path; this avoids a false incremental skip.
- Completion can terminalize explicitly declared per-file failures as `completedWithFailures`. The completion request and report are stored transactionally, so an identical retry recovers a lost response; a different retry returns `job_conflict`.
- Closing the window keeps an active transfer running in the notification area. Double-click the tray icon to reopen it, or use its Show, Stop, and Exit commands. Completion and transfer errors bring the window back and show a notification. Stop and Exit pause active jobs safely before releasing the destination.
- Receiver startup, shutdown, SQLite initialization, certificate creation, QR generation, diagnostics logging, and manifest output never run on the WPF dispatcher. Progress is coalesced to at most ten ordinary updates per second; terminal and error activity is delivered promptly.
- Portable metadata is rebuilt through a receiver-owned scratch SQLite index and streamed into atomic JSONL/CSV/report files, bounding memory to the currently decoded protocol job instead of retaining the entire completed backup history.

The receiver exposes exactly the endpoints documented in `protocol/openapi.yaml`. Tray residency is process-local: it does not install a service, register for autostart, install an updater, or create a firewall rule. Choosing Exit ends the listener and the process.
