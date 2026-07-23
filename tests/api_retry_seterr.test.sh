#!/bin/sh
# Production runs entrypoint.sh with `set -e` (see the top of the script). The
# retry loop uses `A && B` lists and arithmetic that can trip `set -e` if written
# carelessly, so this test exercises the multi-retry path with `set -e` left ON
# and asserts the loop runs to completion instead of aborting early.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
export PATH="$HERE/stub:$PATH"

CURL_STUB_COUNTER=$(mktemp); export CURL_STUB_COUNTER
CURL_STUB_SCENARIO=$(mktemp); export CURL_STUB_SCENARIO
export INPUT_OWNER=cloudbeds INPUT_REPO=argocd-mfd INPUT_GITHUB_TOKEN=x
export API_MAX_ATTEMPTS=4 API_RETRY_BASE_SECONDS=0

# Sourcing re-enables `set -e`; deliberately do NOT disable it afterwards.
TWAW_SOURCE_ONLY=1 . "$ROOT/entrypoint.sh"

S500='500\t{"message":"Failed to run workflow dispatch","status":"500"}'
: > "$CURL_STUB_COUNTER"
printf '%b' "$S500\n$S500\n204\t\n" > "$CURL_STUB_SCENARIO"

# api() calls exit on hard failure and inherits `set -e`; run it in a subshell
# inside an `if` so neither its exit nor a non-zero status aborts this harness.
if ( api "workflows/update-application.yaml/dispatches" --data '{}' >/dev/null 2>&1 ); then
  rc=0
else
  rc=$?
fi
n=$(cat "$CURL_STUB_COUNTER")

if [ "$rc" -eq 0 ] && [ "$n" -eq 3 ]; then
  echo "ok   - retry loop completes cleanly under set -e (3 attempts)"
  exit 0
fi
echo "FAIL - set -e retry path: rc=$rc attempts=$n (want rc=0 attempts=3)"
exit 1
