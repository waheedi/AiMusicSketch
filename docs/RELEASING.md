# Releases

The **macOS build and release** workflow runs for main-branch pushes, pull requests, manual dispatches and version-tag pushes. It checks shell syntax and offline audio scheduling, compiles a universal app, verifies its ad-hoc signature and both architectures, then creates and re-extracts the ZIP and verifies its checksum/signature. Actions are pinned to commit SHAs. Only the tag publication job has repository write permission.

The full native smoke suite (`./scripts/test.sh`) additionally uses a live Core Audio output device and AppKit views. Run it on a development Mac before tagging; it is not claimed as a headless-runner check. Optional installed-library tests require your own sounds.

## Publish a version

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in the root `Info.plist`.
2. Add release notes at `docs/releases/v<VERSION>.md`, including relevant compatibility/signing limitations.
3. Run native smoke tests and commit/push the changes. Wait for the main-branch workflow to pass.
4. Create an annotated tag matching the plist version, for example `git tag -a v0.11.0 -m 'AI Music Sketchpad 0.11.0'`, then `git push origin v0.11.0`.
5. The tag workflow checks the version, builds the package and uploads assets to a draft release. It publishes only after both ZIP and checksum are uploaded successfully. A retry may repair its draft; already-published releases are not overwritten. Do not move a published version tag.

Manual **Run workflow** builds an artifact only; it does not publish a release. No personal access token is needed—the publication job uses its narrowly scoped `GITHUB_TOKEN`.

## Local packaging

```sh
./scripts/build-app.sh --universal
./scripts/package-release.sh
```

The ZIP and `SHA256SUMS.txt` are written under `build/release/`. The ZIP contains only the app, license, README, install instructions and optional AI setup scripts. It does not contain personal recordings, projects, caches, model weights, third-party plug-ins or proprietary sound libraries. Per-architecture SwiftPM builds also work with Command Line Tools, without requiring the full Xcode application.

Releases are currently **ad-hoc signed and not notarized**. For Developer ID distribution, add a separate certificate/notarization setup with protected repository secrets; never commit certificates or credentials. Until then, keep the first-launch warning in release notes and installation instructions.
