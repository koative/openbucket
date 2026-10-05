# Agent notes

Read [CONTRIBUTING.md](CONTRIBUTING.md) first; it is the source of truth for scope and style.

- Layering: S3 concepts and browsing state in `OpenBucketCore`, Soto calls only in the `OpenBucketS3` adapter, SwiftUI and macOS storage in `App`. Only `App/OpenBucketApp.swift` imports the adapter.
- Never commit or log access keys, secrets, session tokens, profile files, or captured authorization headers.
- Verify before handing off (CI runs the same steps):

```sh
swift format lint --strict --recursive App AppTests Packages/OpenBucket/Sources Packages/OpenBucket/Tests
xcodebuild test -project OpenBucket.xcodeproj -scheme OpenBucket -destination 'platform=macOS' -derivedDataPath DerivedData -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
swift test --package-path Packages/OpenBucket
xcodegen generate --spec project.yml  # after changing project.yml; commit the regenerated project
```
