#!/usr/bin/env bash
# End-to-end test of --library with the real tools, run by `make library-test`. Needs podman or docker.
#
#   CONTAINER_ENGINE=docker IMAGE=localhost/kiwix-zim-updater:test test/library-integration.sh
#
# 1. Builds small but real ZIM files with zimwriterfs (zim-tools, Debian trixie).
# 2. Maintains the library with the updater image's own rebuild_library (the script is sourced, so this is exactly
#    the code a run uses, with the image's kiwix-manage).
# 3. Serves it with the official kiwix-serve image (--library --monitorLibrary, ZIM directory mounted read-only) and
#    checks that an added ZIM appears and a purged one disappears, without restarting kiwix-serve.
# Network access: pulling images and apt packages only. Nothing contacts kiwix.org, and the updater image builds
# with `make docker-test` first if IMAGE does not exist.

set -u

ENGINE="${CONTAINER_ENGINE:-}"
IMAGE="${IMAGE:-localhost/kiwix-zim-updater:test}"
SERVE_IMAGE="${SERVE_IMAGE:-ghcr.io/kiwix/kiwix-serve:latest}"
BUILDER_IMAGE="docker.io/library/debian:trixie-slim"
if [[ -z "$ENGINE" ]]; then
  ENGINE="$(command -v podman || command -v docker)" || { echo "library-test: neither podman nor docker found" >&2; exit 1; }
fi
user_opts=(--user "$(id -u):$(id -g)")
[[ "$(basename "$ENGINE")" == podman* ]] && user_opts+=(--userns=keep-id)

failures=0
pass() { echo "ok   $*"; }
fail() {
  echo "FAIL $*"
  failures=$((failures + 1))
}

TMP="$(mktemp -d)"
SERVE_NAME="kiwix-zim-updater-library-test-$$"
cleanup() {
  "$ENGINE" rm -f "$SERVE_NAME" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/data" "$TMP/in"
# A 48x48 PNG, which zimwriterfs requires as the illustration
echo 'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAAAQklEQVR4nO3OQQ0AIAwAsUlBGtKQiguOR5MK6Kx9vjL5QEhISKgeCAkJCdUDISEhoXogJCQkVA+EhISE6oGQkNBjF6vqIJcYXULUAAAAAElFTkSuQmCC' |
  base64 -d >"$TMP/in/icon.png"

if ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "== Building $IMAGE"
  "$ENGINE" build -q -t "$IMAGE" "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" >/dev/null || { echo "build failed"; exit 1; }
fi

# make_zims <name> [<name>...] - real ZIMs titled "Title <name>" in $TMP/data
make_zims() {
  # shellcheck disable=SC2016 # the script runs inside the container, its variables must not expand here
  "$ENGINE" run --rm -v "$TMP/in:/in:ro,z" -v "$TMP/data:/data:z" "$BUILDER_IMAGE" bash -c '
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq --no-install-recommends zim-tools >/dev/null 2>&1 || exit 1
    for name in "$@"; do
      mkdir -p "/tmp/src_$name"
      printf "<html><body>%s</body></html>" "$name" >"/tmp/src_$name/index.html"
      cp /in/icon.png "/tmp/src_$name/"
      zimwriterfs --welcome=index.html --illustration=icon.png --language=eng --title="Title $name" --description=test \
        --creator=test --publisher=test --name="$name" "/tmp/src_$name" "/data/$name.zim" >/dev/null 2>&1 || exit 1
      chmod a+rw "/data/$name.zim"
    done
    chmod a+rwx /data' _ "$@"
}

# rebuild - run the script's rebuild_library on $TMP/data in the updater image
rebuild() {
  # shellcheck disable=SC2016 # the script runs inside the container, its variables must not expand here
  "$ENGINE" run --rm "${user_opts[@]}" --network none -v "$TMP/data:/data:z" --entrypoint bash "$IMAGE" -c '
    source /usr/local/bin/kiwix-zim-updater.sh
    ZIMPath=/data/ LIBRARY_XML=/data/library.xml DEBUG=0 LOG_FILE=/tmp/download.log
    rebuild_library; status=$?
    sleep 3 # let the delayed touch happen before the container goes away
    exit $status'
}

# titles - the book titles kiwix-serve lists right now
titles() {
  curl -s "http://127.0.0.1:$PORT/catalog/v2/entries?count=-1" | grep -o '<title>Title [^<]*</title>' |
    sed 's/<[^>]*>//g' | LC_ALL=C sort | tr '\n' ' '
}

# wait_for <expected titles> - poll kiwix-serve for up to 20 s
wait_for() {
  local _
  for _ in $(seq 1 20); do
    [[ "$(titles)" == "$1" ]] && return 0
    sleep 1
  done
  return 1
}

echo "== Real ZIMs and a first library"
make_zims title_x_2026-01 || { fail "could not build ZIMs with zimwriterfs"; exit 1; }
if rebuild && grep -q 'path="title_x_2026-01.zim"' "$TMP/data/library.xml"; then
  pass "rebuild_library wrote library.xml with a relative path"
else
  fail "no usable library.xml"; cat "$TMP/data/library.xml" 2>&1
fi

echo "== kiwix-serve from $SERVE_IMAGE, ZIM directory read-only"
"$ENGINE" run -d --name "$SERVE_NAME" -p 127.0.0.1::8080 -v "$TMP/data:/data:ro,z" "$SERVE_IMAGE" \
  --library --monitorLibrary /data/library.xml >/dev/null || { fail "kiwix-serve did not start"; exit 1; }
PORT="$("$ENGINE" port "$SERVE_NAME" 8080 | head -n 1 | sed 's/.*://')"
if wait_for "Title title_x_2026-01 "; then pass "serves the first ZIM"; else fail "first ZIM not served: $(titles)"; fi
inode="$(stat -c %i "$TMP/data/library.xml")"

echo "== An update: new version added, then the old one purged"
make_zims title_x_2026-02 || fail "could not build the second ZIM"
rebuild || fail "rebuild after the new ZIM failed"
if wait_for "Title title_x_2026-01 Title title_x_2026-02 "; then
  pass "new ZIM listed while the old one still exists"
else
  fail "new ZIM not picked up: $(titles)"
fi
rm -f "$TMP/data/title_x_2026-01.zim"
rebuild || fail "rebuild after the purge failed"
if wait_for "Title title_x_2026-02 "; then pass "purged ZIM dropped"; else fail "purged ZIM still listed: $(titles)"; fi
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/content/title_x_2026-02/")"
if [[ "$code" == 200 || "$code" == 302 ]]; then pass "new ZIM content served (HTTP $code)"; else fail "new ZIM content: HTTP $code"; fi
if [[ "$(stat -c %i "$TMP/data/library.xml")" == "$inode" ]]; then
  pass "library.xml rewritten in place"
else
  fail "library.xml was replaced"
fi
if [[ "$("$ENGINE" inspect -f '{{.State.Running}}' "$SERVE_NAME")" == "true" ]]; then
  pass "kiwix-serve never restarted"
else
  fail "kiwix-serve stopped"
fi

echo
if [[ $failures -eq 0 ]]; then
  echo "library-test: all checks passed"
else
  echo "library-test: $failures check(s) failed"
  "$ENGINE" logs "$SERVE_NAME" 2>&1 | tail -20
  exit 1
fi
