## Fixes

- Moving or renaming a file over 5 GB that someone else had replaced with a larger one since the folder loaded could finish with the end of the file missing and then delete the original. The copy now uses the file's current size and stops if the file changes while it is being copied. ([#3](https://github.com/koative/openbucket/issues/3))
- Moving or renaming a file over 5 GB without permission to read its tags dropped the tags without saying so. The move now stops with an error instead; services that don't support tags, such as Garage and Cloudflare R2, are unaffected. ([#2](https://github.com/koative/openbucket/issues/2))
- Compare with Local Folder no longer crashes on a malformed multipart ETag from a server; that file is reported as unverified. ([#1](https://github.com/koative/openbucket/issues/1))
- A connection set to the wrong region for an Amazon S3 bucket now says which region the bucket is in, instead of only asking you to check the bucket, region and endpoint.
- The DMG is now signed with Developer ID as well as notarized, so macOS verifies the download itself and not only the app inside.
