# Windows receiver release

Signed Windows artifacts are produced only by `.github/workflows/windows-release.yml` on a protected GitHub-hosted Windows runner.

## One-time repository setup

1. Create a protected GitHub Environment named `windows-code-signing`. Require reviewers for deployments to that environment.
2. Add `WINDOWS_SIGNING_CERTIFICATE_BASE64` as an environment secret. Its value is the Base64 encoding of the code-signing PFX file.
3. Add `WINDOWS_SIGNING_CERTIFICATE_PASSWORD` as an environment secret.
4. Restrict tag creation for `receiver-v*` to release maintainers.

The workflow imports the certificate into the ephemeral runner's current-user certificate store, deletes the temporary PFX before any repository script runs, signs and verifies `MBPhotosReceiver.exe`, and removes the imported certificate in a `finally` block. It never uploads the PFX, certificate password, or unsigned publication directory.

## Publish a release

Create and push an annotated semantic-version tag, for example:

```powershell
git tag -a receiver-v0.1.0 -m "Marginally Better Photos Receiver 0.1.0"
git push origin receiver-v0.1.0
```

The workflow can also be run manually against an existing `receiver-v*` tag. The tagged commit must be on `main`. The release job rebuilds and reruns the Windows integration suite before signing. The GitHub Release contains the signed portable `win-x64` ZIP and a SHA-256 checksum file. Published tags are immutable: the workflow refuses to replace assets on an existing release.

The MVP currently resolves the latest stable .NET 10 SDK on the hosted runner. Before a bit-for-bit reproducibility guarantee is made, generate and review a root `global.json` and NuGet lock files with the production .NET 10 Windows toolchain. Do not fabricate those files with the repository's .NET 7 compatibility target.
