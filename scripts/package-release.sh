#!/bin/bash
set -euo pipefail

version=${1:-}
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/package-release.sh MAJOR.MINOR.PATCH" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
project_version=$(/usr/bin/sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "$root/project.yml")
project_version=${project_version//\"/}
if [[ $project_version != "$version" ]]; then
  echo "project.yml has MARKETING_VERSION ${project_version:-<missing>}; set it to $version and regenerate the project first." >&2
  exit 1
fi

: "${BUCKETDECK_SIGNING_IDENTITY:?Set BUCKETDECK_SIGNING_IDENTITY to your Developer ID Application SHA-1 fingerprint}"
: "${BUCKETDECK_TEAM_ID:?Set BUCKETDECK_TEAM_ID to your Apple Developer team ID}"
: "${BUCKETDECK_NOTARY_PROFILE:?Set BUCKETDECK_NOTARY_PROFILE to a notarytool Keychain profile}"

if [[ ! $BUCKETDECK_SIGNING_IDENTITY =~ ^[[:xdigit:]]{40}$ ]]; then
  echo "Set BUCKETDECK_SIGNING_IDENTITY to the 40-character SHA-1 fingerprint from security find-identity." >&2
  exit 1
fi

identity_record=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -i "$BUCKETDECK_SIGNING_IDENTITY" || true)
if [[ $identity_record != *'"Developer ID Application:'* ]]; then
  echo "The selected fingerprint is not a valid Developer ID Application identity." >&2
  exit 1
fi

if [[ -n $(git -C "$root" status --porcelain) ]]; then
  echo "Commit or discard local changes before packaging a release." >&2
  exit 1
fi

# Apache 2.0 needs the bundled packages' licenses and notices in the app; the About window shows Credits.html.
/usr/bin/python3 "$root/scripts/generate-credits.py" --check

# The DMG keeps one name across releases, so releases/latest/download/Bucketdeck-macOS.dmg is a stable link.
distribution="$root/dist/v$version"
filename="Bucketdeck-macOS.dmg"
destination="$distribution/$filename"
# ponytail: links published before the rename (README, OpenMacApps, posts) ask for the old name; attach a copy under
# it until those are updated, then drop it.
legacy_filename="OpenBucket-macOS.dmg"

mkdir -p "$distribution"
if [[ -e $destination ]]; then
  echo "Release asset already exists: $destination" >&2
  exit 1
fi

work=$(mktemp -d "$distribution/.release.XXXXXX")
trap 'rm -rf "$work"' EXIT

xcodebuild archive \
  -project "$root/Bucketdeck.xcodeproj" \
  -scheme Bucketdeck \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$root/DerivedData/Release" \
  -archivePath "$work/Bucketdeck.xcarchive" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$BUCKETDECK_SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$BUCKETDECK_TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS='--options=runtime --timestamp'

app="$work/Bucketdeck.xcarchive/Products/Applications/Bucketdeck.app"
if [[ ! -d $app ]]; then
  echo "Xcode did not produce Bucketdeck.app in the archive." >&2
  exit 1
fi

actual_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
if [[ $actual_version != "$version" ]]; then
  echo "Archive version $actual_version does not match requested version $version." >&2
  exit 1
fi

build_number=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")
echo "Archived Bucketdeck $actual_version (build $build_number)."

archs=" $(/usr/bin/lipo -archs "$app/Contents/MacOS/Bucketdeck") "
if [[ $archs != *" arm64 "* || $archs != *" x86_64 "* ]]; then
  echo "The archived app is not universal (architectures:$archs); expected arm64 and x86_64." >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

mkdir "$work/volume"
/usr/bin/ditto "$app" "$work/volume/Bucketdeck.app"
ln -s /Applications "$work/volume/Applications"

image="$work/$filename"
/usr/sbin/diskutil image create from \
  --volumeName "Bucketdeck $version" \
  --format UDZO \
  "$work/volume" \
  "$image"

/usr/bin/hdiutil verify "$image"
# Signing the image itself, not only the app inside, lets Gatekeeper verify the download as a whole.
/usr/bin/codesign --sign "$BUCKETDECK_SIGNING_IDENTITY" --timestamp "$image"
/usr/bin/codesign --verify --strict --verbose=2 "$image"
xcrun notarytool submit "$image" \
  --keychain-profile "$BUCKETDECK_NOTARY_PROFILE" \
  --wait \
  --output-format json > "$work/notarization.json"

status=$(/usr/bin/plutil -extract status raw -o - "$work/notarization.json")
if [[ $status != Accepted ]]; then
  cat "$work/notarization.json" >&2
  echo "Notarization was not accepted; no release asset was produced." >&2
  exit 1
fi

xcrun stapler staple "$image"
xcrun stapler validate "$image"
/usr/bin/hdiutil verify "$image"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$image"

mv "$image" "$destination"
cp "$destination" "$distribution/$legacy_filename"
(
  cd "$distribution"
  /usr/bin/shasum -a 256 "$filename" > "$filename.sha256"
  /usr/bin/shasum -a 256 "$legacy_filename" > "$legacy_filename.sha256"
)

echo "Ready to review:"
echo "$destination"
echo "$destination.sha256"
echo "$distribution/$legacy_filename (same image under the pre-rename name)"
