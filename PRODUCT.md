# OpenBucket

<!-- impeccable:product-schema 1 -->

## Platform

web

The designed surface is the project website at https://openbucket.koative.com. The product itself is a native macOS app (SwiftUI, macOS 26+).

## Stack

Website: Astro built with Bun, in `site/` of this repository, deployed by GitHub Actions to GitHub Pages under the custom domain `openbucket.koative.com` (chosen by the owner on 2026-10-17, matching Koative's Maco site). The app: Swift 6, SwiftUI, Soto behind an `S3Repository` adapter, XcodeGen project.

## Users

Mac users who keep files in Amazon S3 or an S3-compatible object store and want to browse, preview, share and manage them in a desktop app instead of a web console or CLI. [Inferred from the README; no audience research exists.]

## Product Purpose

OpenBucket is a native S3 browser for macOS: browse buckets like folders, preview images and video, create share links, download, and, when a connection allows changes, upload, move, rename, delete and restore objects. Success: someone with S3 credentials downloads the signed DMG, connects, and works with their bucket as comfortably as with Finder.

## Positioning

The owner chose these three to lead (2026-10-17):

1. A real Mac app: SwiftUI with the macOS 26 Liquid Glass look, Quick Look, Spotlight favorites, App Intents for Shortcuts, `s3://` links, native multi-selection and keyboard commands, credentials in the macOS Keychain.
2. Amazon S3 and S3-compatible stores: custom HTTP/HTTPS endpoints, path or virtual-host addressing, region, access keys with optional session token or a named AWS CLI profile (roles, IAM Identity Center), and known-bucket access for accounts without `ListBuckets`.
3. Free and open source under the MIT license, distributed as a signed and notarized universal DMG from GitHub Releases.

## Operating Context

Download `OpenBucket-macOS.dmg` from `https://github.com/koative/openbucket/releases/latest/download/OpenBucket-macOS.dmg`, drag to Applications, Add Connection (endpoint, region, keys, optional known bucket and starting folder), browse. Requires macOS 26 or later on Apple silicon or Intel.

## Capabilities and Constraints

- Every connection is read-only until **Allow changes** is turned on for it.
- Shipped in v0.2.0: grid and list browsing, breadcrumbs, Go to Location, favorites and recents, search below a folder, thumbnails and Quick Look, inline video, Info panel (headers, metadata, tags, EXIF), versions and deleted files, Browse As Of, presigned share links (15 min to 7 days, QR code), file/batch/folder downloads and uploads with parallel transfers, Storage Overview treemap, Compare with Local Folder with one-way Update S3 / Update Mac.
- Out of scope today: continuous or two-way sync, Finder mounting, bucket management, permanent deletion of individual versions, non-S3 protocols.
- Early preview software (v0.2.x).
- Compatibility evidence is narrow and must not be overstated: live-tested with Amazon S3 (eu-central-1, including version history and restore), Cloudflare R2, Garage 2.4.1, MinIO RELEASE.2025-10-15, RustFS 1.0.4, SeaweedFS 4.50 and Adobe S3Mock; Ceph, Backblaze B2, Wasabi and others have no live result. Say "Amazon S3 and S3-compatible stores", never "works with every provider".

## Brand Commitments

Name: OpenBucket, published by Koative (github.com/koative). App icon: the blue glass bucket in `App/Resources/Assets.xcassets/AppIcon.appiconset/`. Website copy in English, matching the app and README. [Language inferred from the repository.]

Website direction (owner choice, 2026-10-17): the category standard for a Mac app site, executed straight at the craft level of culturedcode.com/things and apple.com product pages. No novelty concept or costume.

## Evidence on Hand

- Real app screenshots: `docs/media/browser-grid.jpg`, `docs/media/browser-list.jpg`, `docs/media/storage-overview.jpg`. They show a real OpenBucket window against a local Garage bucket filled with fictional demo objects (generated scenery images and a short video in `docs/demo-assets/travel/`).
- Release notes in `docs/releases/`, compatibility in `docs/compatibility.md`, local data and credential handling in `docs/security.md`.
- No testimonials, user counts, press, ratings or benchmarks exist. The repository has very few stars and downloads; never display or invent adoption numbers.

## Product Principles

- Show the real app at work; every visual of the product is a genuine screenshot.
- Claims stay inside the documented evidence, especially provider compatibility.
- Safety is a default, not a feature toggle hunt: read-only until the user allows changes.
- Native first: behave like a Mac app, not a web console in a window.
- One obvious path to the signed download, with the source one click away.