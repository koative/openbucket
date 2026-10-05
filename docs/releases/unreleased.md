# OpenBucket (unreleased)

Changes since v0.1.1. Rename this file to the release version when publishing.

## Highlights

- **Changes to S3**, opt-in per connection with **Allow changes** (off by default): upload files and folders (⌘U, toolbar or Finder drop, multipart for large files), New Folder (⇧⌘N), rename, Move To, drag onto a folder, a parent in the path bar or a sidebar folder (hold ⌥ to copy), delete (⌘⌫), restore versions and deleted files, and edit content headers, metadata and tags. Existing names prompt Replace, Keep Both or Skip.
- **One-way sync** in Compare with Local Folder: after a comparison, **Update S3** uploads new and changed files from this Mac and **Update Mac** downloads new and changed files from S3. Nothing is deleted on either side; a local file that gets replaced goes to the Trash.
- **Transfers side by side**: file, batch and folder downloads, uploads, moves and deletes run alongside each other, four files at a time each, with byte progress, cancellation and failed-key reporting in the transfers bar.
- **Versions**: per-file version history, Show Deleted Files and Browse As Of a date on versioned buckets.
- **Share links**: presigned download or open-in-browser links from 15 minutes to 7 days, with a QR code.
- **Insight**: Storage Overview (treemap by size and kind, storage classes, largest files) and Compare with Local Folder (size and checksum check of a local copy).
- **Connections**: AWS CLI profiles as a credential source, including roles and IAM Identity Center.
- **Navigation**: favorites and recent folders per connection, `s3://` links from other apps, S3 console URLs in Go to Location, search below the current folder, App Intents with favorites in Spotlight, native multi-selection (⌘A, ⇧-click, ⌘-click), context menus, Copy S3 URI, drag-out to Finder, and keyboard commands (Space or ⌘Y Quick Look, ⌘↑, ⌘[ ⌘], ⌘1 ⌘2, ⌘F, ⌥⌘I).
- **Info panel**: inline video playback, photo EXIF, full object details (headers, metadata, tags), and a Show Previews toggle for thumbnails.
- **A quieter, more native window**: breadcrumb path, Finder-style selection, single-line list rows with a Kind column, a Get Info–style Info panel, and redesigned Storage Overview and Compare windows.

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
