# Releasing ProcLens

Build, sign, notarize and package with `scripts/release.sh`. Output goes to `build/release/`.

## One-time setup

1. **Developer ID Application certificate.** Create it at developer.apple.com (Certificates, Identifiers & Profiles), then double-click the `.cer` to install it. Confirm:
   ```sh
   security find-identity -v -p codesigning
   ```
   The release script auto-detects the first `Developer ID Application` identity. To pick a specific one, set `SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"`.
2. **Notary credentials in the keychain.** Run this yourself; it prompts for an app-specific password from appleid.apple.com:
   ```sh
   xcrun notarytool store-credentials proclens-notary --apple-id <apple-id> --team-id <TEAMID>
   ```
   The script reads the profile name from `NOTARY_PROFILE` (default `proclens-notary`). No secrets are stored in the repo.
3. Tools: `brew install xcodegen`. Xcode with command line tools.

## Release steps

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, commit, and tag: `git tag v0.1.1`.
2. Dry run (no signing, no submission):
   ```sh
   scripts/release.sh --dry-run
   ```
3. Full release (signs, notarizes, staples, builds the DMG):
   ```sh
   scripts/release.sh
   ```
   Use `--skip-notarize` for a signed but unnotarized DMG (local testing only). Override the version with `VERSION=0.1.1 scripts/release.sh` when there is no tag.
4. Create the GitHub release and upload the DMG:
   ```sh
   gh release create v0.1.1 build/release/ProcLens-0.1.1.dmg --title "ProcLens 0.1.1" --notes-file <notes>
   ```

## Cask update

Update `Casks/proclens.rb`: set `version` and `sha256` from the script's printed sha256 (also in `build/release/ProcLens-<version>.dmg.sha256`). Commit the cask to the tap repo that serves `brew install --cask proclens`.

## Helper signing (Phase 2+)

- The script signs `Contents/MacOS/ProcLensHelper` or `Contents/Library/LaunchServices/*` before the app, inside-out.
- If `ProcLensHelper/Requirement.txt` exists, `TEAMID_PLACEHOLDER` is replaced with the team id in the built bundle's plists before signing. The rendered text is written to `build/release/Requirement.resolved.txt`.
- The app's and helper's code-signing requirements must match the team id. Check with `codesign -dr- build/DerivedData/Build/Products/Release/ProcLens.app`.

## Troubleshooting

- **Timestamp server errors** (`A timestamp was expected but was not found`, `timestamp service is not available`): transient. Codesign and notary calls retry 3 times. If it persists, re-run; the build is deterministic.
- **notarytool no verdict / network timeouts:** the script retries. Check status with `xcrun notarytool history --keychain-profile proclens-notary`.
- **Notarization `Invalid`:** the script prints the notary log. Common causes: missing hardened runtime, unsigned nested binary, missing `--timestamp`.
- **Gatekeeper rejection** (`spctl` says `rejected`): confirm stapling with `xcrun stapler validate build/DerivedData/Build/Products/Release/ProcLens.app`. Re-run after a fix; stapling needs a successful notarization.
- **`/Volumes/ProcLens` already mounted:** eject it with `hdiutil detach /Volumes/ProcLens -force` and re-run.
- **No Developer ID identity found:** see one-time setup step 1.
