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
4. **Sparkle EdDSA key** (already generated on the maintainer's Mac with `generate_keys --account proclens`). The private key lives only in the login keychain; the public half is `SUPublicEDKey` in `project.yml`. Back it up with `generate_keys --account proclens -x <file>` into a password manager, never into the repo. Losing it means existing installs can no longer verify updates. `sign_update` may show a keychain prompt on first use; allow it.
5. **The repo must be public.** Sparkle reads `appcast.xml` from `raw.githubusercontent.com` and downloads the DMG from GitHub Releases without authentication.

## Release steps

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` (the build number must increase every release; Sparkle compares it), add a `## 0.1.1` section to `CHANGELOG.md` (it becomes the release notes in Sparkle's update dialog), commit, and tag: `git tag v0.1.1`.
2. Dry run (no signing, no submission):
   ```sh
   scripts/release.sh --dry-run
   ```
3. Full release (signs, notarizes, staples, builds the DMG):
   ```sh
   scripts/release.sh
   ```
   The script signs `Sparkle.framework` inside-out (Autoupdate, Updater.app, XPC services, framework), then the helper, then the app. After the DMG is notarized and stapled it runs `sign_update --account proclens` and rewrites `appcast.xml` at the repo root. Use `--skip-notarize` for a signed but unnotarized DMG (local testing only; no appcast is written). Override the version with `VERSION=0.1.1 scripts/release.sh` when there is no tag.
4. Create the GitHub release and upload the DMG:
   ```sh
   gh release create v0.1.1 build/release/ProcLens-0.1.1.dmg --title "ProcLens 0.1.1" --notes-file <notes>
   ```
   The DMG name must stay `ProcLens-<version>.dmg` at tag `v<version>`: the appcast enclosure URL points there.
5. **Commit and push `appcast.xml`** to `main`. Installed apps see the update only after this push, and only if the release asset is already downloadable:
   ```sh
   git add appcast.xml && git commit -m "chore(release): appcast for v0.1.1" && git push
   ```

## Cask update

Update `Casks/proclens.rb`: set `version` and `sha256` from the script's printed sha256 (also in `build/release/ProcLens-<version>.dmg.sha256`). Commit the cask to the tap repo that serves `brew install --cask proclens`.

## Helper signing (Phase 2+)

- The script signs `Contents/MacOS/ProcLensHelper` or `Contents/Library/LaunchServices/*` before the app, inside-out.
- If `ProcLensHelper/Requirement.txt` exists, `TEAMID_PLACEHOLDER` is replaced with the team id in the built bundle's plists before signing. The rendered text is written to `build/release/Requirement.resolved.txt`.
- The app's and helper's code-signing requirements must match the team id. Check with `codesign -dr- build/DerivedData/Build/Products/Release/ProcLens.app`.

## Sparkle notes

- Feed: `https://raw.githubusercontent.com/canberkys/proclens/main/appcast.xml` (`SUFeedURL` in `project.yml`). It is a single-item feed with the latest release only.
- Hardened runtime plus library validation rejects Sparkle.framework in an ad-hoc signed app (different Team ID). Debug builds therefore turn hardened runtime off in `project.yml`; for a local ad-hoc Release build pass `ENABLE_HARDENED_RUNTIME=NO` to `xcodebuild`. Developer ID builds from `scripts/release.sh` are unaffected: every component is signed with one team. Until the repo is public the app logs a feed fetch error; that is expected.
- Test an update end to end by installing an older build, publishing a newer release and appcast, then choosing ProcLens > Check for Updates….

## Troubleshooting

- **Timestamp server errors** (`A timestamp was expected but was not found`, `timestamp service is not available`): transient. Codesign and notary calls retry 3 times. If it persists, re-run; the build is deterministic.
- **notarytool no verdict / network timeouts:** the script retries. Check status with `xcrun notarytool history --keychain-profile proclens-notary`.
- **Notarization `Invalid`:** the script prints the notary log. Common causes: missing hardened runtime, unsigned nested binary, missing `--timestamp`.
- **Gatekeeper rejection** (`spctl` says `rejected`): confirm stapling with `xcrun stapler validate build/DerivedData/Build/Products/Release/ProcLens.app`. Re-run after a fix; stapling needs a successful notarization.
- **`/Volumes/ProcLens` already mounted:** eject it with `hdiutil detach /Volumes/ProcLens -force` and re-run.
- **No Developer ID identity found:** see one-time setup step 1.
