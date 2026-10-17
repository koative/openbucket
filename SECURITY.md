# Security policy

## Reporting a vulnerability

Please don't report vulnerabilities in public issues, pull requests or discussions. Report them privately through GitHub's security advisories:

**[Report a vulnerability](https://github.com/koative/openbucket/security/advisories/new)**

Include the OpenBucket and macOS versions, the provider or endpoint type, steps to reproduce, and what an attacker could do. Never include real access keys, secret keys, session tokens, presigned URLs or captured authorization headers; use a disposable bucket and revoked credentials if a reproduction needs them. You'll get a reply in the advisory, and a fix is released as a new version with the advisory published once users can update.

## Supported versions

Only the [latest release](https://github.com/koative/openbucket/releases/latest) receives security fixes. Older versions are not patched; update to the newest release first and check whether the problem still occurs.

## Scope

[Local data and credential handling](docs/security.md) describes what OpenBucket stores on the Mac, how credentials are kept in the Keychain, how temporary files and downloads are handled, what changes S3, and how share links work. Behavior that contradicts that document is in scope. Problems in an S3 provider, in Soto or in macOS itself should go to their maintainers; tell us too if OpenBucket makes them worse.
