#!/usr/bin/env bash
# Tests for the transient-error retry behaviour of entrypoint.sh's api() helper.
# Runs the real api() against a scripted `curl` stub (tests/stub/curl).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# Put the curl stub first on PATH; every other tool (jq, sed, mktemp) stays real.
export PATH="$HERE/stub:$PATH"

export CURL_STUB_COUNTER
CURL_STUB_COUNTER=$(mktemp)
export CURL_STUB_SCENARIO
CURL_STUB_SCENARIO=$(mktemp)
trap 'rm -f "$CURL_STUB_COUNTER" "$CURL_STUB_SCENARIO"' EXIT

# Values api() reads to build the request URL (contents irrelevant to the stub).
export INPUT_OWNER=cloudbeds INPUT_REPO=argocd-mfd INPUT_GITHUB_TOKEN=x
# Retry knobs: keep attempts small and eliminate real sleeping so tests are fast.
export API_MAX_ATTEMPTS=4
export API_RETRY_BASE_SECONDS=0

# Source the script for its functions only; do not run main.
# shellcheck disable=SC1090
TWAW_SOURCE_ONLY=1 . "$ROOT/entrypoint.sh"
set +e  # entrypoint.sh enables `set -e`; disable it so the harness controls flow.

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
die()  { printf 'FAIL - %s\n' "$1"; fail=1; }

# scenario "<printf-escaped lines>" resets the counter and writes the response script.
scenario() { : > "$CURL_STUB_COUNTER"; printf '%b' "$1" > "$CURL_STUB_SCENARIO"; }
attempts() { cat "$CURL_STUB_COUNTER"; }

S500='500\t{"message":"Failed to run workflow dispatch","status":"500"}'

# --- Test 1: transient 500s then success --------------------------------------
# GitHub's dispatch endpoint intermittently returns a 500 with this exact body
# (no "Server Error" string). api() must retry and ultimately succeed.
scenario "$S500\n$S500\n204\t\n"
# api() calls `exit` on hard failure, so always invoke it in a subshell.
out=$(api "workflows/update-application.yaml/dispatches" --data '{}' 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ "$(attempts)" -eq 3 ]; then
  pass "retries transient 500 then succeeds (3 attempts)"
else
  die "retries transient 500 then succeeds: rc=$rc attempts=$(attempts) (want rc=0 attempts=3)"
fi

# --- Test 2: genuine 4xx fails fast, no retry ---------------------------------
scenario '404\t{"message":"Not Found"}\n'
out=$(api "workflows/missing.yaml/dispatches" --data '{}' 2>/dev/null); rc=$?
if [ "$rc" -ne 0 ] && [ "$(attempts)" -eq 1 ]; then
  pass "does not retry a 4xx (fails fast in 1 attempt)"
else
  die "does not retry a 4xx: rc=$rc attempts=$(attempts) (want rc!=0 attempts=1)"
fi

# --- Test 3: persistent 500 exhausts retries then fails ------------------------
scenario "$S500\n$S500\n$S500\n$S500\n$S500\n"
out=$(api "workflows/update-application.yaml/dispatches" --data '{}' 2>/dev/null); rc=$?
if [ "$rc" -ne 0 ] && [ "$(attempts)" -eq "$API_MAX_ATTEMPTS" ]; then
  pass "gives up after API_MAX_ATTEMPTS on persistent 500 (surfaces failure)"
else
  die "persistent 500 exhausts retries: rc=$rc attempts=$(attempts) (want rc!=0 attempts=$API_MAX_ATTEMPTS)"
fi

# --- Test 4: transport error (no HTTP response) is retried --------------------
scenario 'NETERR\n200\t{"ok":true}\n'
if out=$(api "runs/123" 2>/dev/null); then rc=0; else rc=$?; fi
if [ "$rc" -eq 0 ] && [ "$(attempts)" -eq 2 ] && printf '%s' "$out" | grep -q '"ok":true'; then
  pass "retries a transport failure then succeeds (2 attempts)"
else
  die "retries a transport failure: rc=$rc attempts=$(attempts) out=$out"
fi

# --- Test 5: a 429 (rate limit) is retried like a 5xx -------------------------
scenario '429\t{"message":"API rate limit exceeded"}\n204\t\n'
out=$(api "workflows/update-application.yaml/dispatches" --data '{}' 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ "$(attempts)" -eq 2 ]; then
  pass "retries a 429 then succeeds (2 attempts)"
else
  die "retries a 429: rc=$rc attempts=$(attempts) (want rc=0 attempts=2)"
fi

# --- Test 6: backoff doubles each retry and caps at API_RETRY_MAX_SECONDS ------
# The sleep stub records each requested delay (via SLEEP_LOG) instead of really
# sleeping, so the backoff sequence can be asserted without waiting. With base 3
# and cap 10 over 5 persistent failures, the delays are 3, 6, 10 (12 capped), 10.
SLEEP_LOG=$(mktemp)
scenario "$S500\n$S500\n$S500\n$S500\n$S500\n"
out=$(
  export SLEEP_LOG API_RETRY_BASE_SECONDS=3 API_RETRY_MAX_SECONDS=10 API_MAX_ATTEMPTS=5
  api "workflows/update-application.yaml/dispatches" --data '{}' 2>/dev/null
); rc=$?
seq=$(tr '\n' ' ' < "$SLEEP_LOG" | sed 's/ *$//')
rm -f "$SLEEP_LOG"
if [ "$rc" -ne 0 ] && [ "$(attempts)" -eq 5 ] && [ "$seq" = "3 6 10 10" ]; then
  pass "backoff doubles then caps at API_RETRY_MAX_SECONDS (delays: 3 6 10 10)"
else
  die "backoff sequence: rc=$rc attempts=$(attempts) delays=[$seq] (want attempts=5 delays='3 6 10 10')"
fi

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
