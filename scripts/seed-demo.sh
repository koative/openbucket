#!/bin/sh
set -eu

: "${OPENBUCKET_DEMO_ENDPOINT:?Set the S3 endpoint URL}"
: "${OPENBUCKET_DEMO_REGION:?Set the S3 region}"
: "${OPENBUCKET_DEMO_BUCKET:?Set the bucket name}"
: "${OPENBUCKET_DEMO_ACCESS_KEY:?Set the access key}"
: "${OPENBUCKET_DEMO_SECRET_KEY:?Set the secret key}"

case "$OPENBUCKET_DEMO_ENDPOINT" in
  http://*|https://*) ;;
  *) printf '%s\n' 'The endpoint must be an HTTP or HTTPS URL.' >&2; exit 1 ;;
esac
case "$OPENBUCKET_DEMO_BUCKET" in
  ''|*[!a-zA-Z0-9.-]*) printf '%s\n' 'Invalid bucket name.' >&2; exit 1 ;;
esac

prefix=${OPENBUCKET_DEMO_PREFIX:-openbucket-demo/travel/}
case "$prefix" in
  ''|/*|*[!a-zA-Z0-9/_-]*) printf '%s\n' 'Use a simple relative prefix.' >&2; exit 1 ;;
esac
case "$prefix" in */) ;; *) prefix="$prefix/" ;; esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
endpoint=${OPENBUCKET_DEMO_ENDPOINT%/}
# Credentials reach curl as a config on stdin through the printf builtin, never on any argv.
curl_user=$(printf '%s:%s' "$OPENBUCKET_DEMO_ACCESS_KEY" "$OPENBUCKET_DEMO_SECRET_KEY" | sed 's/[\\"]/\\&/g')

for name in alpine-meadow.png city-after-rain.png coastal-cliffs.png desert-dunes.png fjord-dawn.png fjord-pan.mp4; do
  case "$name" in
    *.mp4) content_type=video/mp4 ;;
    *) content_type=image/png ;;
  esac
  printf 'user = "%s"\n' "$curl_user" | curl --config - --fail --silent --show-error \
    --aws-sigv4 "aws:amz:$OPENBUCKET_DEMO_REGION:s3" \
    --header "Content-Type: $content_type" \
    --upload-file "$root/docs/demo-assets/travel/$name" \
    "$endpoint/$OPENBUCKET_DEMO_BUCKET/$prefix$name" \
    --output /dev/null
  printf 'Uploaded %s\n' "$name"
done

printf 'Open s3://%s/%s in OpenBucket.\n' "$OPENBUCKET_DEMO_BUCKET" "$prefix"
