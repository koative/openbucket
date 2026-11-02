## What changed and why

<!-- Link the issue this addresses, if any. -->

## Checks

App changes (see [CONTRIBUTING.md](https://github.com/koative/bucketdeck/blob/main/CONTRIBUTING.md)):

- [ ] `swift format lint --strict --recursive App AppTests Packages/Bucketdeck/Sources Packages/Bucketdeck/Tests`
- [ ] `xcodebuild test -project Bucketdeck.xcodeproj -scheme Bucketdeck -destination 'platform=macOS' -derivedDataPath DerivedData -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO`
- [ ] `swift test --package-path Packages/Bucketdeck`
- [ ] After changing `project.yml`: ran `xcodegen generate --spec project.yml` and committed `Bucketdeck.xcodeproj`
- [ ] After a dependency change: committed the updated `Packages/Bucketdeck/Package.resolved`
- [ ] New write actions: name the S3 operation, progress, cancellation, partial failure and versioned-bucket behavior, and extend `writeRoundTrip`

Website changes in `site/`:

- [ ] `bun install`, `bun run check` and `bun run build` in `site/`

Every change:

- [ ] No access keys, secrets, session tokens, profile files, presigned links or authorization headers are committed
