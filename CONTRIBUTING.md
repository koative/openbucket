# Contributing to OpenBucket

OpenBucket currently targets macOS 26+ and Swift 6. Use the installed Xcode toolchain and format changed Swift files with `swift format`. Before opening a pull request, run the same checks as CI:

```sh
swift format lint --strict --recursive App AppTests Packages/OpenBucket/Sources Packages/OpenBucket/Tests
xcodebuild test -project OpenBucket.xcodeproj -scheme OpenBucket -destination 'platform=macOS' -derivedDataPath DerivedData -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
swift test --package-path Packages/OpenBucket
```

`OpenBucket.xcodeproj` is generated from `project.yml`. After changing `project.yml`, run `xcodegen generate --spec project.yml` and commit the result; CI fails if the committed project differs from a fresh generation. `Packages/OpenBucket/Package.resolved` is the only lockfile: Xcode follows it, and CI and release builds refuse to re-resolve packages. After a dependency change, run `swift package resolve --package-path Packages/OpenBucket` and commit the updated `Package.resolved`.

Keep S3 concepts in `OpenBucketCore`, SDK calls in `OpenBucketS3`, and macOS-specific storage and views in `App`; only `App/OpenBucketApp.swift` imports the adapter. Add protocols at external boundaries when substitution is useful. Preserve object keys exactly and treat prefixes as listing filters. Keep implementation comments rare; document public contracts and compatibility rules that are not obvious from code.

For behavior changes, add a test at the boundary where the behavior is visible. Endpoint construction tests should inspect the SDK-generated request. Local S3 integration tests use an isolated service and environment variables; never commit access keys, secrets, profile files, or captured authorization headers.

Writes are opt-in per connection (**Allow changes**, off by default). A new write action should name the S3 operation, its progress and cancellation behavior, partial-failure handling, and what happens on versioned buckets, and extend the `writeRoundTrip` integration test before the user interface changes.
