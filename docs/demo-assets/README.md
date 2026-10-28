# Demo objects

Fictional sample objects for screenshots and local S3 testing. They contain no user data or credentials.

- `travel/`: five generated scenery images and a three-second video made from one of them.
- `studio/`: twelve generated photos for the fictional outdoor brand Kestrel's autumn 2026 campaign, and two short videos made from them.

Run [`scripts/seed-demo.sh`](../../scripts/seed-demo.sh) against two disposable buckets (`kestrel-studio` and `kestrel-platform` by default) to upload them, together with generated placeholder backups, logs, releases, exports and customer uploads (about 3,300 objects).

## Generating the studio images

The studio photos are generated with an image model (Gemini). Generate each one as a **3:2 landscape** image at the highest resolution available, with this shared style, then the per-image prompt below, and save it as `studio/<name>.png`:

> Editorial outdoor-brand campaign photograph, autumn 2026 collection. Warm palette of rust, ochre, deep green and slate; soft natural light; shallow depth of field; shot on a full-frame camera with a 35mm lens; realistic, not illustrated. No text, no logos, no watermarks, no visible faces.

| File | Prompt |
| --- | --- |
| `aw26-hero-ridge` | A lone hiker seen from behind on a mountain ridge at golden hour, wearing a rust-colored jacket and a canvas backpack, golden larch trees on the slope below, layered blue mountains fading into haze. |
| `aw26-larch-forest` | A forest of golden larch trees in morning fog, a narrow dirt trail curving through it, light rays between the trunks. |
| `aw26-tent-dusk` | An orange tent glowing from inside at blue hour on the shore of a still alpine lake, dark peaks behind, first stars in the sky. |
| `aw26-pack-on-granite` | Product photograph of a rust-colored waxed-canvas backpack with leather straps resting on a lichen-covered granite boulder, blurred autumn forest behind. |
| `aw26-wool-jacket` | A heavy ochre wool shirt-jacket hanging on a wooden peg inside a timber cabin, soft window light, texture of the wool clearly visible. |
| `aw26-thermos-steam` | A brushed-steel thermos cup with steam rising, standing on a frosty rock at sunrise, frozen grass around it. |
| `aw26-boots-detail` | Close-up of worn brown leather hiking boots on a mossy forest trail covered in fallen yellow leaves. |
| `aw26-lake-mirror` | A perfectly still alpine lake reflecting autumn-colored slopes and a snow-dusted peak, a few rocks in the foreground. |
| `aw26-gear-flatlay` | Overhead flat lay on a weathered wooden table: folded paper trail map, brass compass, knit beanie, leather gloves, enamel mug. |
| `aw26-cabin-window` | View from inside a dark timber cabin through a large window onto a misty valley with autumn trees, a mug on the windowsill. |
| `aw26-campfire` | A small campfire at dusk with a blackened enamel kettle on a grate, sparks rising, pine trees silhouetted behind. |
| `aw26-blanket-flatlay` | Overhead flat lay of a rust and cream wool blanket with a knit beanie, wool socks and a leather-bound notebook on it. |

With Antigravity, open this repository and ask its agent: *"Read docs/demo-assets/README.md and generate every image in the studio table with the shared style, saving each as docs/demo-assets/studio/<File>.png."*

Then convert each PNG to JPEG and make the two videos:

```sh
cd docs/demo-assets/studio
for f in *.png; do sips -s format jpeg -s formatOptions 88 "$f" --out "${f%.png}.jpg" >/dev/null && rm "$f"; done
ffmpeg -loop 1 -i aw26-hero-ridge.jpg -vf "scale=3840:-2,zoompan=z='1.15-0.0015*on':x='iw/2-(iw/zoom/2)+on*2':y='ih/2-(ih/zoom/2)':d=150:s=1920x1280:fps=30" -t 5 -c:v libx264 -pix_fmt yuv420p -crf 23 aw26-ridge-pan.mp4
ffmpeg -loop 1 -i aw26-lake-mirror.jpg -vf "scale=3840:-2,zoompan=z='1+0.0012*on':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=150:s=1920x1280:fps=30" -t 5 -c:v libx264 -pix_fmt yuv420p -crf 23 aw26-lake-drift.mp4
```

## Capturing screenshots

The README and website show real windows. To keep them sharp and their corners clean:

1. Run a disposable Garage (any S3 store works) and seed it with `scripts/seed-demo.sh`.
2. Add two connections: **Kestrel Studio** (known bucket `kestrel-studio`, Allow changes on) and **Kestrel Platform** (known bucket `kestrel-platform`, read-only). Favorite `campaigns/2026-autumn/`, `backups/postgres/` and `releases/desktop/`.
3. Run the app in US English so sizes and dates read `2.1 MB` and `Oct 28, 2026`: `defaults write dev.openbucket.app AppleLocale en_US` and `defaults write dev.openbucket.app AppleLanguages -array en-US`. If the Mac's accent color is Graphite, the traffic lights and selections turn grey; give the app the blue accent with `defaults write dev.openbucket.app AppleAccentColor -int 4` and `defaults write dev.openbucket.app AppleAquaColorVariant -int 1`. Delete all four keys afterwards.
4. Size the main window to 1440×880 points, keep it the active window (colored traffic lights), and capture it on a Retina display with `screencapture -o -l <window-id> shot.png`. `-o` drops the system shadow; the PNG keeps the window's transparent corners.
5. Save the full windows as PNG in `docs/media/`. **Never convert them to JPEG**: JPEG fills the transparent corners with white, and no CSS radius matches the macOS corner curve. The website turns them into 1x and 2x WebP at build time and keeps the alpha.
6. Cut the website's crops from those PNGs with ffmpeg, which keeps the alpha:

```sh
crop() { ffmpeg -v error -y -i "$1" -vf "crop=$3:$4:$5:$6" "$2"; }
crop docs/media/browser-list.png site/src/assets/list-detail.png 2356 800 524 116
crop docs/media/browser-grid.png site/src/assets/grid-phone.png 1760 1100 1120 0
crop docs/media/storage-overview.png site/src/assets/overview-phone.png 918 1280 0 0
```
