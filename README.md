<div align="center">

<img src="App/Resources/Assets.xcassets/AppIcon.appiconset/icon-128.png" width="88" alt="OpenBucket app icon">

# OpenBucket

**A native S3 browser for macOS. Browse, preview, share, and manage the objects in your buckets.**

<a href="https://github.com/koative/openbucket/releases/latest/download/OpenBucket-macOS.dmg"><img src="https://img.shields.io/badge/Download_for_macOS-0A84FF?style=for-the-badge&logo=apple&logoColor=white" height="40" alt="Download OpenBucket for macOS"></a>

![Latest release](https://img.shields.io/github/v/release/koative/openbucket?label=latest&color=18181b)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-18181b?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white)
![MIT license](https://img.shields.io/badge/license-MIT-8b8bd4)

</div>

OpenBucket is an early macOS app for Amazon S3 and S3-compatible object stores. Every connection is read-only until you turn on **Allow changes** for it. It uses SwiftUI, the macOS 26 Liquid Glass appearance, and [Soto](https://github.com/soto-project/soto) behind a replaceable S3 adapter. It stays focused on S3 rather than adding unrelated file protocols.

## Download

Use the **Download for macOS** button above: it always fetches the newest signed and notarized `OpenBucket-macOS.dmg` from [GitHub Releases](https://github.com/koative/openbucket/releases/latest). Open the DMG, drag OpenBucket to Applications, and launch it from there. OpenBucket runs on Apple silicon and Intel Macs with macOS 26 or later; every release lists its changes and a SHA-256 checksum. See [how releases are prepared](docs/RELEASING.md).

## See it in action

The screenshots show a real OpenBucket window connected to a local Garage bucket with the demo images and video from [`docs/demo-assets`](docs/demo-assets).

![Grid view of the demo travel folder with image and video thumbnails, a selected photo, and the Info panel with details and photo dimensions](docs/media/browser-grid.jpg)

![List view with name, size, modified and kind columns, a selected photo, and the Info panel](docs/media/browser-list.jpg)

![Storage Overview of the travel folder: a treemap of its files by size and kind, the storage class, and the largest files](docs/media/storage-overview.jpg)

## What works

| Area | Current behavior |
| --- | --- |
| Connections | Multiple profiles, custom HTTP or HTTPS endpoints, region and addressing style, access keys with an optional session token or a named AWS CLI profile (static keys, roles, IAM Identity Center after `aws sso login`) |
| Restricted accounts | Open a known bucket without account-wide `ListBuckets` permission; start in a chosen folder |
| Browsing | Grid and sortable native table, breadcrumb path, folder navigation, `s3://` links (also opened from other apps) and S3 console URLs in Go to Location, favorites and recent folders per connection, filter and search below the current folder, refresh, incremental `ListObjectsV2` loading |
| Selection and commands | Native multi-selection in grid and list (⌘A, ⇧-click, ⌘-click); menu commands and shortcuts for the enclosing folder (⌘↑), back and forward (⌘[ ⌘]), grid and list (⌘1 ⌘2), Find (⌘F) and the Info panel (⌥⌘I); context menus; Copy S3 URI |
| Media and details | Image and video thumbnails with a Show Previews toggle; Quick Look with Space or ⌘Y; inline video playback; HEAD details, user metadata, tags and photo EXIF in the Info panel |
| Versions | Version history per file with Quick Look, download and restore; Show Deleted Files (⇧⌘.) and Browse As Of a date on versioned buckets |
| Downloads and links | File, batch and whole-folder downloads with byte progress, cancellation and failed-key reporting; several transfers at once, each moving four files at a time; drag files out to Finder; presigned share links (15 minutes to 7 days) with QR code |
| Changes | With **Allow changes** on: upload files and folders (⌘U, toolbar or Finder drop; large files in multipart parts), New Folder (⇧⌘N), rename, Move To or drag items onto a folder, a parent in the path bar or a sidebar folder (hold ⌥ to copy instead), Delete (⌘⌫), restore versions and deleted files, edit content headers, metadata and tags. Existing names prompt Replace, Keep Both or Skip |
| Insight and sync | Storage Overview: treemap of a folder by size and kind, storage classes and largest files. Compare with Local Folder: checks a local copy against S3 by size and checksum, then optionally **Update S3** or **Update Mac** with the new and changed files; nothing is deleted on either side, and replaced local files go to the Trash |
| Shortcuts | App Intents for opening a favorite or an `s3://` location and copying a share link; favorites appear in Spotlight |
| Secrets | Access keys and session tokens in macOS Keychain; non-secret connection settings in a user-only profile file |

Continuous or two-way sync, Finder mounting, bucket management, permanent deletion of individual versions and non-S3 protocols are outside this preview. [Compatibility details](docs/compatibility.md) document endpoint paths, the S3 operations used, and provider test status; [security details](docs/security.md) explain local storage, temporary files, and what changes S3.

## Connect to S3

After installing the app:

1. Choose **Add Connection**.
2. Enter the S3 endpoint URL and region. For a custom service such as Garage, choose **Path style** if its buckets live beneath the endpoint path.
3. Enter an access key and secret. Set **Known bucket** when the key cannot list all buckets. **Starting folder** is optional and opens a folder inside that bucket.
4. Test the connection, save it, and browse. Use the toolbar's location action to jump directly to `s3://bucket/folder/`. To upload or change files, edit the connection and turn on **Allow changes**.

The endpoint URL path and the starting folder are separate. For example, endpoint `https://store.example.com/s3/`, known bucket `photos`, and starting folder `2026/travel/` address objects under the bucket without dropping `/s3/` from the signed request. A proxy must preserve the signed request path. See [endpoint behavior](docs/compatibility.md#endpoint-paths).

## Build and test

Building from source requires **macOS 26 or later** and **Xcode 27**. Open `OpenBucket.xcodeproj`, select the `OpenBucket` scheme, and run it on your Mac. The Xcode project is committed; [XcodeGen](https://github.com/yonaskolb/XcodeGen) is needed only after changing `project.yml`:

```sh
xcodegen generate --spec project.yml
```

```sh
swift format lint --strict --recursive App AppTests Packages/OpenBucket/Sources Packages/OpenBucket/Tests
xcodebuild test -project OpenBucket.xcodeproj -scheme OpenBucket -destination 'platform=macOS' -derivedDataPath DerivedData -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
swift test --package-path Packages/OpenBucket
```

Unit tests need no AWS account. The optional live S3 test uses an isolated bucket and environment variables documented in [compatibility testing](docs/compatibility.md#live-compatibility-test). GitHub Actions runs the format check, app tests, package tests, and a check that the committed Xcode project matches `project.yml` on an Xcode 27 runner.

## How the code is organized

```mermaid
flowchart LR
    UI[SwiftUI app] --> Core[OpenBucketCore]
    UI --> Local[Profiles + Keychain]
    Core --> Port[S3Repository protocol]
    Port --> Adapter[OpenBucketS3 adapter]
    Adapter --> Soto[Soto]
    Soto --> Store[(S3 endpoint)]
```

`OpenBucketCore` owns S3 values and browsing state. `OpenBucketS3` adapts Soto and keeps SDK types outside the UI. `App` contains SwiftUI and macOS storage; `OpenBucketApp` wires them together. The adapter boundary allows the SDK implementation to change without reshaping the browser.

Contributions are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md). OpenBucket is licensed under [MIT](LICENSE).
