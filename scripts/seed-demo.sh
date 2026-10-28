#!/bin/sh
# Fills two disposable buckets with the fictional Kestrel demo: campaign media in the studio bucket and
# generated backups, logs, releases, exports and uploads in the platform bucket. See docs/demo-assets/README.md.
set -eu

: "${OPENBUCKET_DEMO_ENDPOINT:?Set the S3 endpoint URL}"
: "${OPENBUCKET_DEMO_REGION:?Set the S3 region}"
: "${OPENBUCKET_DEMO_ACCESS_KEY:?Set the access key}"
: "${OPENBUCKET_DEMO_SECRET_KEY:?Set the secret key}"
studio=${OPENBUCKET_DEMO_STUDIO_BUCKET:-kestrel-studio}
platform=${OPENBUCKET_DEMO_PLATFORM_BUCKET:-kestrel-platform}

case "$OPENBUCKET_DEMO_ENDPOINT" in
  http://*|https://*) ;;
  *) printf '%s\n' 'The endpoint must be an HTTP or HTTPS URL.' >&2; exit 1 ;;
esac
for bucket in "$studio" "$platform"; do
  case "$bucket" in
    ''|*[!a-z0-9.-]*) printf 'Invalid bucket name: %s\n' "$bucket" >&2; exit 1 ;;
  esac
done

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
list=$work/uploads

# add <file> <bucket/key>
add() { printf '%s\n%s\n' "$1" "$2" >> "$list"; }
# sparse <path> <MB>: placeholder bytes for large backups and installers; nobody opens them.
sparse() { dd if=/dev/zero of="$1" bs=1 count=0 seek="$2"m 2>/dev/null; }

# Studio: the autumn campaign (generated photos and videos) and the summer one (the travel set).
for file in "$root"/docs/demo-assets/studio/* "$root"/docs/demo-assets/travel/*; do
  [ -f "$file" ] || continue
  case "$file" in
    */studio/*) add "$file" "$studio/campaigns/2026-autumn/${file##*/}" ;;
    *) add "$file" "$studio/campaigns/2026-summer/${file##*/}" ;;
  esac
done

# The autumn campaign's selects as one real ZIP, and its shot list as a PDF.
set -- "$root"/docs/demo-assets/studio/*.jpg
if [ -f "$1" ]; then
  zip -q -0 -j "$work/aw26-selects.zip" "$@"
  add "$work/aw26-selects.zip" "$studio/campaigns/2026-autumn/aw26-selects.zip"
  for file in "$@"; do name=${file##*/}; printf '%s\n' "${name%.*}"; done | nl -w2 -s'  ' |
    { printf 'Kestrel AW26 campaign: shot list\n\n'; cat; } > "$work/shot-list.txt"
  cupsfilter "$work/shot-list.txt" > "$work/aw26-shot-list.pdf" 2>/dev/null
  add "$work/aw26-shot-list.pdf" "$studio/campaigns/2026-autumn/aw26-shot-list.pdf"
fi

# Platform: two weeks of database backups, growing a little every day.
mkdir -p "$work/backups"
for day in 15 16 17 18 19 20 21 22 23 24 25 26 27 28; do
  sparse "$work/backups/prod-2026-10-$day.sql.gz" $((560 + day * 4))
  add "$work/backups/prod-2026-10-$day.sql.gz" "$platform/backups/postgres/prod-2026-10-$day.sql.gz"
  sparse "$work/backups/sessions-2026-10-$day.rdb.gz" $((30 + day))
  add "$work/backups/sessions-2026-10-$day.rdb.gz" "$platform/backups/redis/sessions-2026-10-$day.rdb.gz"
done

# Desktop app releases.
mkdir -p "$work/releases"
for version in 2.3.1:171 2.3.2:174 2.4.0:186; do
  v=${version%%:*} mb=${version##*:}
  sparse "$work/releases/Kestrel-$v-universal.dmg" "$mb"
  sparse "$work/releases/Kestrel-$v.zip" $((mb - 12))
  printf '{"version":"%s","url":"https://downloads.kestrel.example/desktop/v%s/Kestrel-%s-universal.dmg"}\n' \
    "$v" "$v" "$v" > "$work/releases/latest-$v.json"
  add "$work/releases/Kestrel-$v-universal.dmg" "$platform/releases/desktop/v$v/Kestrel-$v-universal.dmg"
  add "$work/releases/Kestrel-$v.zip" "$platform/releases/desktop/v$v/Kestrel-$v.zip"
  add "$work/releases/latest-$v.json" "$platform/releases/desktop/v$v/latest.json"
done

# Monthly analytics exports: real CSV text.
mkdir -p "$work/exports"
for month in 01 02 03 04 05 06 07 08 09 10; do
  awk -v m="$month" -v rows=$((90000 + 1${month} * 1500)) 'BEGIN {
    srand(m); print "date,order_id,sku,region,quantity,revenue_eur"
    for (i = 0; i < rows; i++)
      printf "2026-%s-%02d,KST-%07d,AW26-%03d,%s,%d,%.2f\n", m, i % 28 + 1, i, i % 140,
        substr("EU-WEST EU-NORTH US-EAST US-WEST APAC", (i % 5) * 8 + 1, 7), i % 4 + 1, 20 + (i * 37 % 400)
  }' > "$work/exports/orders-2026-$month.csv"
  add "$work/exports/orders-2026-$month.csv" "$platform/exports/analytics/orders-2026-$month.csv"
done

# A day of API logs: 24 hours, 60 small gzip files each.
mkdir -p "$work/logs"
hour=0
while [ $hour -lt 24 ]; do
  h=$(printf '%02d' $hour) part=0
  while [ $part -lt 60 ]; do
    p=$(printf '%04d' $part)
    printf '{"ts":"2026-10-27T%s:%02d:00Z","level":"info","route":"/v1/orders","status":200}\n' "$h" $((part % 60)) |
      gzip > "$work/logs/$h-$p.jsonl.gz"
    add "$work/logs/$h-$p.jsonl.gz" "$platform/logs/api/2026/10/27/$h/part-$p.jsonl.gz"
    part=$((part + 1))
  done
  hour=$((hour + 1))
done

# Customer uploads: full-size copies of the demo photos under random IDs.
i=0
while [ $i -lt 1800 ]; do
  for file in "$root"/docs/demo-assets/travel/*.png "$root"/docs/demo-assets/studio/*.jpg; do
    [ -f "$file" ] && [ $i -lt 1800 ] || continue
    add "$file" "$platform/user-uploads/$(uuidgen | tr 'A-Z' 'a-z').${file##*.}"
    i=$((i + 1))
  done
done

# Credentials reach curl as a config on stdin through the printf builtin, never on any argv.
OB_CURL_USER=$(printf '%s:%s' "$OPENBUCKET_DEMO_ACCESS_KEY" "$OPENBUCKET_DEMO_SECRET_KEY" | sed 's/[\\"]/\\&/g')
OB_ENDPOINT=${OPENBUCKET_DEMO_ENDPOINT%/}
OB_REGION=$OPENBUCKET_DEMO_REGION
export OB_CURL_USER OB_ENDPOINT OB_REGION
tr '\n' '\0' < "$list" | xargs -0 -n 2 -P 8 sh -c '
  case "$1" in
    *.jpg) type=image/jpeg ;; *.png) type=image/png ;; *.mp4) type=video/mp4 ;; *.gz) type=application/gzip ;;
    *.csv) type=text/csv ;; *.json) type=application/json ;; *.zip) type=application/zip ;; *.pdf) type=application/pdf ;;
    *.dmg) type=application/x-apple-diskimage ;; *) type=application/octet-stream ;;
  esac
  printf "user = \"%s\"\n" "$OB_CURL_USER" | curl --config - --fail --silent --show-error \
    --aws-sigv4 "aws:amz:$OB_REGION:s3" --header "Content-Type: $type" \
    --upload-file "$0" "$OB_ENDPOINT/$1" --output /dev/null'

printf 'Uploaded %s objects to s3://%s and s3://%s.\n' $(($(wc -l < "$list") / 2)) "$studio" "$platform"
