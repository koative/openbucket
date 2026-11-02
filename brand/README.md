# Bucketdeck brand assets

| Path | What it is | Use it for |
| --- | --- | --- |
| `../App/AppIcon.icon` | The app icon, authored in Icon Composer: two nested bands on a blue ground, each band its own Liquid Glass layer, with a dark appearance (blue bands on graphite) | The app itself. Open it with Icon Composer to edit; Xcode compiles it |
| `app-icon/bucketdeck-{32,64,128,256,512,1024}.png` | macOS's own rendering of that icon, with the system shape, margin and shadow | README, website, favicon, store listings, anywhere the app is shown |
| `mark/bucketdeck-mark.svg` | The flat mark in blue (`#0071E3`), no glass and no background | Small or single-colour use: docs, print, a wordmark lockup |
| `mark/bucketdeck-mark-white.svg` | The flat mark in white | On blue or dark backgrounds |
| `banner/bucketdeck-banner.jpg` | The campaign banner (1264 × 848): icon, name, tagline and a composed app window on midnight blue. Owner-supplied artwork, not a literal screenshot | Product covers (koative.com), launch posts, the GitHub social preview |
| `../site/public/og.png` | The 1200 × 630 share card, cut from the banner | Link previews of bucketdeck.com |

Show the app icon as it is: no extra rounding, glow or shadow, since the image already carries what macOS draws. Don't recolour or rearrange the bands. The name and icon are Koative LLC's and are not covered by the code license.

## Regenerating

After editing `App/AppIcon.icon`, build the app and re-render the PNGs from it, so they match what macOS shows:

```sh
xcodebuild build -project Bucketdeck.xcodeproj -scheme Bucketdeck -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
```

Then draw `NSWorkspace.shared.icon(forFile:)` of `DerivedData/Build/Products/Debug/Bucketdeck.app` (an absolute path; a relative one returns the generic document icon) into a bitmap of each size and save it as PNG. To preview every appearance of the source icon directly:

```sh
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for R in Default Dark TintedLight TintedDark ClearLight ClearDark; do
  "$ICTOOL" App/AppIcon.icon --export-image --output-file "/tmp/AppIcon-$R.png" \
    --platform macOS --rendition "$R" --width 512 --height 512 --scale 2
done
```

The share card is the banner scaled to 1200 px wide and cropped to 630 px, 20 px from the top:

```sh
ffmpeg -i brand/banner/bucketdeck-banner.jpg -vf "scale=1200:-2:flags=lanczos,crop=1200:630:0:20" -frames:v 1 site/public/og.png
```
