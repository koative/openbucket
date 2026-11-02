# Contributing to Bucketdeck

Bucketdeck currently targets macOS 26+ and Swift 6. Use the installed Xcode toolchain and format changed Swift files with `swift format`. Before opening a pull request, run the same checks as CI:

```sh
swift format lint --strict --recursive App AppTests Packages/Bucketdeck/Sources Packages/Bucketdeck/Tests
xcodebuild test -project Bucketdeck.xcodeproj -scheme Bucketdeck -destination 'platform=macOS' -derivedDataPath DerivedData -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
swift test --package-path Packages/Bucketdeck
```

`Bucketdeck.xcodeproj` is generated from `project.yml`. After changing `project.yml`, run `xcodegen generate --spec project.yml` and commit the result; CI fails if the committed project differs from a fresh generation. `Packages/Bucketdeck/Package.resolved` is the app's only lockfile: Xcode follows it, and CI and release builds refuse to re-resolve packages. After a dependency change, run `swift package resolve --package-path Packages/Bucketdeck` and commit the updated `Package.resolved`.

The website at [bucketdeck.com](https://bucketdeck.com) lives in `site/` (Astro, Bun 1.4.3 or later, locked by `site/bun.lock`). The Swift checks above don't cover it, and CI skips pushes and pull requests that change only `site/`. For website changes, run `bun install`, `bun run check` and `bun run build` in `site/`; `bun run dev` serves it locally.

Keep S3 concepts in `BucketdeckCore`, SDK calls in `BucketdeckS3`, and macOS-specific storage and views in `App`; only `App/BucketdeckApp.swift` imports the adapter. Add protocols at external boundaries when substitution is useful. Preserve object keys exactly and treat prefixes as listing filters. Keep implementation comments rare; document public contracts and compatibility rules that are not obvious from code.

For behavior changes, add a test at the boundary where the behavior is visible. Endpoint construction tests should inspect the SDK-generated request. Local S3 integration tests use an isolated service and environment variables; never commit access keys, secrets, profile files, or captured authorization headers.

Writes are opt-in per connection (**Allow changes**, off by default). A new write action should name the S3 operation, its progress and cancellation behavior, partial-failure handling, and what happens on versioned buckets, and extend the `writeRoundTrip` integration test before the user interface changes.

Report security problems privately as described in [SECURITY.md](SECURITY.md), not in a public issue or pull request.

## License of contributions

Bucketdeck is licensed under the GNU General Public License, version 3. By submitting a contribution, you license it under the GPL-3.0 and also grant Koative LLC a perpetual, worldwide, irrevocable, royalty-free license to distribute and sublicense your contribution under other terms, including in Mac App Store builds and paid editions. You confirm that you wrote the contribution or otherwise have the right to submit it under these terms.
