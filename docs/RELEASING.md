# Releasing OpenBucket for macOS

Users download the app from [GitHub Releases](https://github.com/koative/openbucket/releases). Each published release has a version tag, release notes, a DMG named `OpenBucket-macOS.dmg`, and a matching `.sha256` file. Because the name never changes, `https://github.com/koative/openbucket/releases/latest/download/OpenBucket-macOS.dmg` (the README's download button) always downloads the newest release. The DMG contains a universal Apple silicon and Intel `OpenBucket.app` and an Applications shortcut. GitHub's source archives are for developers; they are not the app installer.

Publish only after the DMG is signed with Developer ID, accepted by Apple's notary service, stapled, and tested from the downloaded file. [Apple's direct-distribution guidance](https://developer.apple.com/documentation/technologyoverviews/distribution) explains why this matters for Gatekeeper.

## One-time setup

1. If your **Developer ID Application** signing identity already exists on another Mac, export it there as a password-protected `.p12` from **Xcode → Settings → Accounts → your team → Manage Certificates**, then double-click the `.p12` on this Mac to import the certificate **and private key**. A downloaded `.cer` alone cannot sign without its matching private key. Keep the `.p12` and its password private. See [Apple's identity sharing guide](https://developer.apple.com/documentation/Xcode/sharing-your-teams-signing-certificates).
2. If you need a new identity, create its request on the Mac that will build releases: **Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority**. Enter your Apple Account email and a name, leave the CA email empty, and save the `.certSigningRequest` to disk. The matching private key stays in this Mac's Keychain. Follow [Apple's CSR instructions](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request). As the Apple Developer Program Account Holder, open [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list), add a certificate under **Software → Developer ID → Developer ID Application**, upload the CSR, download the `.cer`, and double-click it to install it. A DMG needs the Application certificate; the Installer certificate is for `.pkg` installers. See [Apple's Developer ID certificate guide](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).
3. Confirm that `security find-identity -v -p codesigning` lists a valid `Developer ID Application` identity. For a new certificate, choose the **G2 Sub-CA** option in Apple's portal; the Previous Sub-CA expires in February 2027. If more than one identity has the same name, identify the intended certificate by its SHA-1 fingerprint. Find your ten-character Team ID in [Apple Developer membership details](https://developer.apple.com/account). Generate an app-specific password at [account.apple.com](https://account.apple.com) under **Sign-In and Security → App-Specific Passwords**. Name it for OpenBucket notarization. Do not use your regular Apple Account password.
4. Create a local notarytool Keychain profile. The following command prompts for that app-specific password securely; do not put it in the repository or shell history:

   ```sh
   xcrun notarytool store-credentials openbucket-release \
     --apple-id YOUR_APPLE_ID \
     --team-id YOUR_TEAM_ID
   ```

5. Set the 40-character SHA-1 fingerprint of the intended Developer ID Application identity from `security find-identity` and your team ID in your shell. Keep the notary profile in Keychain:

   ```sh
   export OPENBUCKET_SIGNING_IDENTITY='40_CHARACTER_SHA1_FINGERPRINT'
   export OPENBUCKET_TEAM_ID='TEAMID'
   export OPENBUCKET_NOTARY_PROFILE='openbucket-release'
   ```

The project disables signing for ordinary local and CI builds. The release script enables Developer ID signing and Hardened Runtime for its archive. This local workflow keeps the certificate's private key and notarization credentials in the Mac's Keychain rather than uploading them to GitHub Actions.

## Prepare a release

1. Set the new `MARKETING_VERSION` and a higher `CURRENT_PROJECT_VERSION` (build number) in `project.yml`, regenerate `OpenBucket.xcodeproj` with `xcodegen generate --spec project.yml`, and rename `docs/releases/unreleased.md` to `docs/releases/vVERSION.md`, adding the version heading and install section used by earlier notes.
2. Run the format check, app tests, and package tests shown in the main README. Make sure `Packages/OpenBucket/Package.resolved` is committed; the release archive refuses to re-resolve packages, so it builds exactly those versions. Commit and push a clean `main` branch and wait for CI to pass.
3. Build and notarize the DMG:

   ```sh
   VERSION=0.2.0
   scripts/package-release.sh "$VERSION"
   ```

   The script refuses to run when the version you pass differs from `MARKETING_VERSION` in `project.yml`, and it refuses to put an unnotarized image in `dist/`. It prints the archived version and build number, checks that the app is a universal binary containing both `arm64` and `x86_64`, verifies the app signature, waits for notarization to be accepted, staples the ticket to the DMG, verifies the DMG, and writes it with its SHA-256 checksum to `dist/vVERSION/`. `dist/` is ignored by Git.

4. Mount the DMG and test the app after copying it to Applications. Check a fresh connection, a known bucket and starting folder, a media thumbnail, a single and a batch download, and first launch from a downloaded copy. On a disposable bucket with **Allow changes** on, also check an upload, a drag-to-move, a delete and Update Mac in Compare with Local Folder. Test on another Mac when possible.
5. Tag the exact tested commit and create a **draft** GitHub release:

   ```sh
   VERSION=0.2.0
   git tag -a "v$VERSION" -m "OpenBucket v$VERSION"
   git push origin "v$VERSION"
   gh release create "v$VERSION" \
     "dist/v$VERSION/OpenBucket-macOS.dmg" \
     "dist/v$VERSION/OpenBucket-macOS.dmg.sha256" \
     --draft --verify-tag \
     --title "OpenBucket v$VERSION" \
     --notes-file "docs/releases/v$VERSION.md"
   ```

6. Review the draft's assets, notes, and download on GitHub, then publish it. The stable link for users is `https://github.com/koative/openbucket/releases/latest`.

Do not reuse a version tag for different app bits. Fixes after publishing get a new version and a new tag.
