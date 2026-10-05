# Local data and credential handling

OpenBucket has no app database. Non-secret connection settings live in `~/Library/Application Support/OpenBucket/profiles.json`, within a user-only directory and with user-only file permissions. The JSON contains a random credential reference, not the access key, secret key, or session token. If `profiles.json` cannot be read, OpenBucket moves it aside as `profiles.unreadable-<timestamp>.json` in the same folder instead of overwriting it on the next save.

Credentials are stored as generic password items in the login Keychain only. Editing a connection updates its existing Keychain item in place. The data-protection Keychain would need a Keychain access-group entitlement backed by a provisioning profile; this project ships neither, so no build, including signed Developer ID releases, uses it. The app reads a connection's credentials from the Keychain once when the connection is selected and keeps them in memory while it stays selected.

Image and video thumbnails are downloaded only for objects up to 8 MB; larger images can still show the thumbnail embedded in their first 256 KB, read with a range request. Quick Look preview is an explicit action and has a 64 MB limit. Their local copies use private (`0700`) temporary directories and are removed after use. A crash can leave a temporary preview until the operating system clears its temporary directory. Files dragged to Finder are downloaded into the same kind of private temporary directory; because OpenBucket can't tell when the receiving app has finished copying, those copies are left for macOS to clean up. Videos too large for Quick Look play inline from a one-hour presigned link and are not written to disk.

Downloads stream into the system's temporary-items folder on the destination volume, which macOS cleans up, then move into place atomically only after the transfer completes. A failed or cancelled download leaves an existing destination intact. Saved files get normal user file permissions, like any other file you save.

A batch download creates a new `OpenBucket Export-*` folder inside the chosen directory; completed files stay there if a later file fails or the batch is cancelled. Each file name is derived from the object key and reduced to a single safe path component, so a key can never place a file outside that folder. Names are made unique case-insensitively, so two selected objects never overwrite each other, even on a case-insensitive volume.

The included demo seeder is separate from the app. It reads credentials from environment variables, passes them to `curl` on standard input rather than on the command line, and uploads only the six named demo objects to the bucket and prefix you choose. It does not modify the app's Keychain or profile file.

## Changes to S3

Every connection starts read-only. Upload, New Folder, rename, Move To, Delete, Restore and metadata editing are available only after **Allow changes** is turned on in that connection's settings; connections saved by earlier versions load with it off. The app checks the setting again before each request rather than relying on disabled menu items. Credentials that can't write still fail at S3 with an access-denied message.

Uploading a folder sends its regular files and skips hidden files (such as `.DS_Store`) and symbolic links. Rename and Move To copy each object and delete the source only after its copy succeeded. Delete asks for confirmation; on a bucket without versioning it is permanent, and on a versioned bucket it adds delete markers that Show Deleted Files can restore. Saving metadata rewrites the object in place.

Sync in Compare with Local Folder runs only after a complete comparison and a confirmation that lists what it will do. It never deletes on either side. **Update S3** needs **Allow changes** and replaces changed objects; the confirmation says so when the bucket has no versioning. **Update Mac** only reads S3: each download is written to a temporary file on the same volume first, and only once it has finished does the file it replaces move to the Trash and the new copy take its place, so a failed or cancelled download leaves the old file where it was. Keys that would resolve outside the chosen folder (such as `../`) are refused.

## Share links

Share links are presigned `GET` URLs signed on this Mac with the connection's credentials; no request is made to create them. Anyone with the link can download that object (or that version) until it expires, after 15 minutes to 7 days. When the connection uses temporary credentials, the link can't outlive them, so its expiry is shortened to match.
