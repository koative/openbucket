# S3 compatibility

OpenBucket browses, downloads and, on connections with **Allow changes** turned on, changes objects through the `OpenBucketS3` adapter. Provider compatibility is an observed result, not a guarantee implied by the phrase “S3-compatible.”

| Provider or configuration | Current evidence |
| --- | --- |
| Garage 2.4.1, direct endpoint, path style | Live tests passed for a known bucket and nested prefix and for the write round trip below; the local demo screenshots use this setup. Garage has no versioning or object tagging |
| Adobe S3Mock (latest), path style | Write round trip passed. S3Mock keeps listing deleted keys in `ListObjectsV2`, keeps the old Content-Type on a metadata-replacing copy, and rejects an unchanged copy onto the same key |
| Custom endpoint with a path, path style | A request-construction test checks that Soto signs the endpoint path followed by the bucket path |
| Amazon S3 | Soto adapter implemented; no account-backed live test in this repository yet |
| MinIO and RustFS | No live compatibility result yet |
| Path-rewriting reverse proxy | Not verified; rewriting a SigV4-signed path can break authentication |

The app uses `ListObjectsV2` with `/` as the delimiter. Each request asks for at most 500 entries; more entries load as you scroll. Each listing request times out after 20 seconds. A known bucket lets an account browse even if it cannot call account-wide `ListBuckets`. Listings request S3 URL encoding for keys that XML cannot represent, and decode only when the response declares URL encoding. Decoding follows Amazon S3 and MinIO: `+` becomes a space, and literal percent signs in keys remain intact. A response marked as truncated without a continuation token is reported as an error rather than shown as a complete listing.

## Changes

Changes are sent only for connections with **Allow changes** turned on. They use these operations:

| Action | S3 operations |
| --- | --- |
| Upload | `PutObject` up to 16 MiB; above that `CreateMultipartUpload`, `UploadPart` (parts of at least 16 MiB, at most 10,000 parts) and `CompleteMultipartUpload`, or `AbortMultipartUpload` after a failure or cancel. Content-Type comes from the file extension |
| New Folder | `PutObject` of an empty `folder/` marker |
| Rename, Move To, drag to a folder | `CopyObject` (multipart `UploadPartCopy` above 5 GiB) then `DeleteObjects` for each copied source; a source whose copy failed is kept. ⌥-drop copies without the delete |
| Delete | `DeleteObjects` in batches of 1,000 without version IDs, so versioned buckets keep the data behind a delete marker |
| Restore | `CopyObject` of the chosen version onto its own key, which makes it the newest version |
| Metadata and tags | `CopyObject` onto the same key with replaced headers, then `PutObjectTagging` or `DeleteObjectTagging` when tags changed |
| Update S3 (Compare window) | Upload as above for files that are new or changed on this Mac; nothing is deleted |

Transfers run side by side, and each works on up to four files (or four `DeleteObjects` batches) at a time.

Existing destinations are found by listing the destination prefix first; a name that already exists prompts Replace, Keep Both (`name 2.ext`) or Skip. Delete reads `GetBucketVersioning` to say whether deleted files can be restored. The opt-in write round trip uploads a small and a multipart file, creates a folder marker, copies, replaces metadata and deletes everything under a fresh prefix:

```sh
OPENBUCKET_TEST_WRITES=1 swift test --package-path Packages/OpenBucket --filter writeRoundTrip
```

It needs the endpoint, region, bucket and key variables from the [live compatibility test](#live-compatibility-test) and a bucket you can write to.

## Endpoint paths

The endpoint path and the starting folder are separate settings. With endpoint `https://store.example.com/s3/`, bucket `photos`, and path-style addressing, requests use a path beneath `/s3/photos`. Starting folder `2026/travel/` is an object-key prefix that filters keys **inside** that bucket; it does not change the endpoint base path.

Soto uses path-style addressing by default for custom endpoints. Virtual-host addressing works with a pathless endpoint such as `https://store.example.com`. OpenBucket rejects virtual-host addressing with an endpoint path because Soto constructs an incompatible URL for that combination. It also rejects virtual-host addressing for a bucket name that contains dots, instead of silently switching that bucket to path style; choose **Automatic** or **Path style** for such buckets. Percent-encoded endpoint paths are rejected too, because Soto can rewrite them while building the signed request.

Soto selects virtual-host addressing for standard Amazon endpoints even when path style is requested for a regular named bucket. OpenBucket reports that unsupported combination instead of silently changing the requested addressing mode. A gateway with a path prefix must receive the path that was signed; a proxy that rewrites it is a different configuration and needs its own live test.

## Live compatibility test

The provider-neutral integration test is opt-in. Supply an isolated bucket with an existing object under the test prefix:

```text
OPENBUCKET_TEST_ENDPOINT
OPENBUCKET_TEST_REGION
OPENBUCKET_TEST_BUCKET
OPENBUCKET_TEST_ACCESS_KEY
OPENBUCKET_TEST_SECRET_KEY
OPENBUCKET_TEST_PREFIX
OPENBUCKET_TEST_EXPECT_KEY
```

Then run:

```sh
swift test --package-path Packages/OpenBucket --filter listsKnownBucketAndNestedPrefix
```

Use the same test against each provider before calling it verified. Never commit credentials or captured authorization headers.

## SDK boundary

The first adapter candidate was the official AWS SDK for Swift, but its approximately 2.4 GB repository did not finish fetching on the development machine within 18 minutes. Soto resolved and passes the Garage and endpoint-path tests; the exact versions are pinned in `Packages/OpenBucket/Package.resolved`. `OpenBucketCore` depends on an S3 repository protocol, so the SDK can be changed without rewriting browser views.
