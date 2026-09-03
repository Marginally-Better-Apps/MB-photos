# MB Photos Windows Receiver

The Windows app receives a portable MB Photos library from iOS and can reopen that library to browse and export its verified representations. It listens while the receiver is running, including when its WPF window is hidden in the notification area, and accepts one certificate-pinned session on a private IPv4 LAN.

## Projects

- `src/MBPhotos.Receiver.Core` contains the protocol-v2 HTTPS host, pairing, SQLite ledger, path security, incremental planning, chunk transfer, Master promotion, portable catalog, exact-copy variant export, reports, and diagnostics. It targets .NET 10 in production and conditionally targets .NET 7 only when built by the older SDK installed on the repository's macOS host.
- `src/MBPhotos.Receiver.Wpf` is the .NET 10 Windows x64 UI and portable single-file publish target.
- `tests/MBPhotos.Receiver.Tests` is a dependency-free console test runner. It executes the shared protocol fixtures and every normative Windows path vector, then exercises the real SQLite/transfer implementation.
- `tests/MBPhotos.Receiver.Wpf.Tests` exercises versioned settings, presentation-state fencing, safe preview loading, malformed-image fallback, and file-handle release on Windows.

## Build and test

Production prerequisites are the .NET 10 SDK on Windows 10 22H2 or Windows 11:

```powershell
dotnet restore windows/MBPhotos.Windows.sln
dotnet build windows/MBPhotos.Windows.sln -c Release
dotnet run --project windows/tests/MBPhotos.Receiver.Tests/MBPhotos.Receiver.Tests.csproj -c Release --no-build
dotnet run --project windows/tests/MBPhotos.Receiver.Wpf.Tests/MBPhotos.Receiver.Wpf.Tests.csproj -c Release --no-build
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

- The first successful library root is saved in versioned per-user settings and starts automatically on later launches. Choosing an empty uninitialized folder requires an explicit confirmation; missing remembered locations and nonempty invalid destinations are never recreated. Nonempty reserved `Master` or `MB Photos Data` paths are rejected and left untouched. Legacy v1 destinations are detected and rejected without modification.
- Each process run creates a self-signed process-lifetime certificate, a renewable 256-bit five-minute pairing invitation, and a replaceable bearer session. An expired unused invitation refreshes without restarting the listener; pairing and job admission retract the displayed invitation, while a terminal response publishes a fresh invitation and retains the bearer for idempotent retries. Windows uses a temporary current-user key container because Schannel cannot serve TLS from an ephemeral private key; it is not persisted beyond certificate disposal. Tokens, filenames, album titles, and location values are redacted from diagnostics.
- Uploads use sequential 8 MiB chunks. Receipts, the first observed total for unknown-size outputs, and original receipt timestamps are durable in SQLite. Retrying an acknowledged chunk is idempotent.
- Each chunk and complete file is SHA-256 verified. Files are received below `MB Photos Data/.mbphotos/staging`; verified support resources are retained below `MB Photos Data/Resources`, and verified current representations are safely promoted below `Master`.
- Crash reconciliation truncates bytes flushed without a ledger receipt and recognizes a hash-valid final file moved before its commit transaction.
- Existing or externally changed files are never overwritten. Updating a managed Master representation first verifies the prior cataloged hash; a mismatch stops that asset's promotion and leaves the external file untouched.
- All output paths are revalidated at the Windows security boundary. Rooted/traversal/device paths and any existing symbolic-link or junction ancestor are rejected.
- Stable per-resource identities and content revisions allow a nondestructive edit to replace only the current Master representation while unchanged originals and Live Photo motion remain verified.
- Completion can terminalize explicitly declared per-file failures as `completedWithFailures`. The completion request and report are stored transactionally, so an identical retry recovers a lost response; a different retry returns `job_conflict`.
- Closing the window keeps an active transfer running in the notification area. Double-click the tray icon to reopen it, or use its Show, Pause/Start, and Exit commands. Completion and transfer errors bring the window back and show a notification. A manual pause lasts for the process lifetime; entering Library safely stops receiving, and returning starts it again with a fresh invitation unless receiving was manually paused first. Stop and Exit pause active jobs safely before releasing the destination.
- Receiver startup, shutdown, SQLite initialization, certificate creation, QR generation, diagnostics logging, and manifest output never run on the WPF dispatcher. Progress is coalesced to at most ten ordinary updates per second; terminal and error activity is delivered promptly.
- Redacted process and transfer diagnostics are written continuously to `%LOCALAPPDATA%\MarginallyBetterPhotos\Receiver\receiver.log`. The log includes app lifecycle and presentation changes, request boundaries, manifest and plan counts, and method-only managed exception stacks; pairing tokens, filenames, album titles, location values, exception messages, and source paths are not recorded. Fatal managed exceptions force a log flush before the process exits.
- Portable metadata is published as immutable catalog generations with an atomic `current.json` pointer. Catalog paths are relative to the library root, so moving the complete root preserves the library.

The selected root has two intentionally different areas:

- `Master/` contains only one current photo or video per successfully synced asset and may be copied on its own.
- `MB Photos Data/` contains exact originals, Live Photo motion, adjustment resources, thumbnails, catalogs, reports, and receiver state required for reversible exports.

Opening a library in the Windows app enables exact-copy export of the current Master file, individual untouched originals, and current/original Live Photo MOV resources. These exports do not transcode media or modify Master.

The receiver exposes exactly the protocol-v2 endpoints documented in `protocol/openapi-v2.yaml`. Tray residency is process-local: it does not install a service, register for autostart, install an updater, or create a firewall rule. Choosing Exit ends the listener and the process.
