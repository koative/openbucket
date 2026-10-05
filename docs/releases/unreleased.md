# OpenBucket (unreleased)

Changes since v0.1.1. Rename this file to the release version when publishing.

## Highlights

- Changes to S3, per connection: turn on **Allow changes** to upload files and folders (⌘U, toolbar or Finder drop, multipart for large files), create folders (⇧⌘N), rename, move (Move To, or drag files and folders onto a folder or a parent in the path bar), delete (⌘⌫), restore versions and deleted files, and edit content headers, metadata and tags. Existing names prompt Replace, Keep Both or Skip. Connections stay read-only by default.
- Versions: per-file version history, Show Deleted Files and Browse As Of a date on versioned buckets.
- Share links: presigned download or open-in-browser links from 15 minutes to 7 days, with a QR code.
- Storage Overview (treemap by size and kind, storage classes, largest files) and Compare with Local Folder (checks a local copy by size and checksum).
- AWS CLI profiles as a credential source, including roles and IAM Identity Center.
- Favorites and recent folders per connection, `s3://` links from other apps, S3 console URLs in Go to Location, search below the current folder, and App Intents with favorites in Spotlight.
- Inline video playback, photo EXIF and full object details (headers, metadata, tags) in the Info panel; folder downloads.
- A quieter, more native window: breadcrumb path, Finder-style selection, single-line list rows with a Kind column, a Get Info–style Info panel, redesigned Storage Overview and Compare windows.
- Native multi-selection in grid and list, with ⌘A, ⇧-click, and ⌘-click.
- Keyboard navigation and menu commands: Quick Look with Space or ⌘Y, enclosing folder with ⌘↑, back and forward with ⌘[ and ⌘], grid and list with ⌘1 and ⌘2, Find with ⌘F, and the Info panel with ⌥⌘I.
- Context menus on files and folders, drag-out to Finder, and Copy S3 URI.
- Single and batch downloads show byte progress and can be cancelled.
- A Show Previews toggle for image and video thumbnails.

## Fixes

- Moving through the list with the arrow keys no longer opens every folder it passes.
- Saved connections are no longer lost when `profiles.json` can't be read; the unreadable file is kept as `profiles.unreadable-<timestamp>.json`.
- Credentials are read from the Keychain once per selected connection instead of rewriting the Keychain item on every request.
- Deleting a connection reports failures, and cancelling the delete confirmation no longer switches connections.
- Files and folders with spaces in their names now display and download correctly on Amazon S3 and MinIO, which send spaces as `+` in URL-encoded listings.
- Listings that end without a continuation token are reported instead of silently stopping, and slow listings get 20 seconds before timing out.
- Listing and download errors name the actual problem (network, timeout, permissions, missing bucket, local file) instead of a generic connection failure.
- Virtual-host addressing with a dotted bucket name is rejected with an explanation instead of silently switching to path style.
- Downloaded files get normal user permissions, and interrupted downloads no longer leave hidden partial files next to the destination.
- Export file names derived from object keys always stay inside the export folder, and collisions are detected case-insensitively.
- Filenames truncate in the middle so their extension stays visible.
- Menu shortcuts such as ⌘U, ⌘F and ⌘⌫ work as soon as they apply, instead of only after their menu was opened once.
- Quick Look no longer crashes when it opens a video after another preview.
