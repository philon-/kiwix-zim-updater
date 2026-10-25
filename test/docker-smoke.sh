#!/usr/bin/env bash
# Smoke tests for the container image, run by `make docker-test`. Needs podman or docker.
#
#   CONTAINER_ENGINE=docker IMAGE=localhost/kiwix-zim-updater:test test/docker-smoke.sh
#
# Builds the image, then runs it offline: every run uses the wget stub and the fixtures from the test harness, so
# nothing contacts kiwix.org. The only network access is the image build (base image and apt packages).

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${CONTAINER_ENGINE:-}"
IMAGE="${IMAGE:-localhost/kiwix-zim-updater:test}"
STUB_PATH="/stubs:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ -z "$ENGINE" ]]; then
  ENGINE="$(command -v podman || command -v docker)" || { echo "docker-test: neither podman nor docker found" >&2; exit 1; }
fi

build_opts=()
run_opts=(--rm)
# No container gets a network: the stubs serve everything, and nothing can reach kiwix.org by mistake
container_opts=(--network none)
if [[ "$(basename "$ENGINE")" == podman* ]]; then
  # The OCI image format drops HEALTHCHECK; keep-id maps the calling user into the container unchanged
  build_opts+=(--format docker)
  container_opts+=(--userns=keep-id)
fi
# Run as the calling user, so the temporary directories below are writable and removable afterwards
container_opts+=(--user "$(id -u):$(id -g)")

failures=0
pass() { echo "ok   $*"; }
fail() {
  echo "FAIL $*"
  failures=$((failures + 1))
}

TMP="$(mktemp -d)"
cleanup() {
  [[ -n "${CONTAINER_ID:-}" ]] && "$ENGINE" rm -f "$CONTAINER_ID" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== Building $IMAGE with $ENGINE"
if ! "$ENGINE" build "${build_opts[@]}" -t "$IMAGE" "$REPO_ROOT"; then
  echo "docker-test: build failed" >&2
  exit 1
fi
size="$("$ENGINE" image inspect --format '{{.Size}}' "$IMAGE")"
echo "== Image size: $(numfmt --to=iec "$size") ($size bytes)"

# Private copies of the stubs and fixtures: relabelling them for SELinux (:z) must not touch the repository
mkdir -p "$TMP/stubs" "$TMP/fixtures" "$TMP/zims" "$TMP/state"
cp -r "$REPO_ROOT/test/helpers/bin/." "$TMP/stubs/"
cp -r "$REPO_ROOT/test/fixtures/." "$TMP/fixtures/"
# An outdated ZIM with a newer version in the fixture catalog, and one that is up to date
printf 'local zim wikipedia_en_test_2025-12.zim\n' >"$TMP/zims/wikipedia_en_test_2025-12.zim"
printf 'local zim wiktionary_fr_test_2026-02a.zim\n' >"$TMP/zims/wiktionary_fr_test_2026-02a.zim"

offline=(
  -v "$TMP/stubs:/stubs:ro,z" -v "$TMP/fixtures:/fixtures:ro,z"
  -v "$TMP/zims:/data:z" -v "$TMP/state:/state:z"
  -e "PATH=$STUB_PATH" -e FAKE_FIXTURES=/fixtures
)
snapshot() { (cd "$TMP/zims" && find . -mindepth 1 -printf '%P %s %T@\n' | LC_ALL=C sort); }

echo "== -h"
out="$("$ENGINE" run "${run_opts[@]}" --network none "$IMAGE" -h 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == Usage:* ]]; then pass "-h exits 0 and prints the usage"; else fail "-h: exit $status: $out"; fi

echo "== --version"
expected="$(grep -oP '^VER="\K[^"]+' "$REPO_ROOT/kiwix-zim-updater.sh")"
out="$("$ENGINE" run "${run_opts[@]}" --network none "$IMAGE" --version 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == "$expected" ]]; then pass "--version prints $out"; else fail "--version: exit $status: $out"; fi

echo "== Default user"
out="$("$ENGINE" run "${run_opts[@]}" --network none --entrypoint id "$IMAGE" -u 2>&1)"
if [[ "$out" == "1000" ]]; then pass "runs as uid 1000"; else fail "default uid is '$out'"; fi

echo "== Healthcheck before any run"
if "$ENGINE" run "${run_opts[@]}" "${container_opts[@]}" -v "$TMP/state:/state:z" --entrypoint healthcheck.sh "$IMAGE"; then
  pass "healthy without a finished run"
else
  fail "unhealthy without a finished run"
fi

echo "== Offline dry-run from the environment (RUN_INTERVAL=once)"
before="$(snapshot)"
out="$("$ENGINE" run "${run_opts[@]}" "${container_opts[@]}" "${offline[@]}" -e RUN_INTERVAL=once "$IMAGE" 2>&1)"
status=$?
if [[ $status -eq 0 ]]; then pass "dry-run exits 0"; else fail "dry-run exit $status"; echo "$out"; fi
if [[ "$out" == *"run 1 started: kiwix-zim-updater.sh -w -c --clean-partials /data"* ]]; then
  pass "options built from the defaults"
else
  fail "unexpected options:"; echo "$out" | grep 'docker-entrypoint'
fi
if [[ "$out" == *"*** Simulated *** New zim exists, old zim purged"* ]]; then
  pass "the outdated ZIM is found"
else
  fail "no simulated update in the output"; echo "$out"
fi
if [[ "$(snapshot)" == "$before" ]]; then pass "ZIM directory unchanged"; else fail "ZIM directory changed"; snapshot; fi
if [[ -s "$TMP/state/download.log" && -s "$TMP/state/kiwix-index" ]]; then
  pass "download.log and kiwix-index are in /state"
else
  fail "download.log or kiwix-index missing from /state"; ls -la "$TMP/state"
fi
if grep -qE '^exit=0 time=[0-9T:-]+Z$' "$TMP/state/last-run" 2>/dev/null; then
  pass "last-run: $(cat "$TMP/state/last-run")"
else
  fail "last-run: $(cat "$TMP/state/last-run" 2>&1)"
fi

echo "== MIN_FREE_SPACE reaches the script as --min-free"
out="$("$ENGINE" run "${run_opts[@]}" "${container_opts[@]}" "${offline[@]}" -e RUN_INTERVAL=once -e MIN_FREE_SPACE=1Mi "$IMAGE" 2>&1)"
status=$?
if [[ $status -eq 0 ]] && [[ "$out" == *"--min-free 1Mi"* ]]; then
  pass "--min-free 1Mi accepted"
else
  fail "MIN_FREE_SPACE run exit $status"; echo "$out" | tail -20
fi

echo "== Healthcheck after the run"
if "$ENGINE" run "${run_opts[@]}" "${container_opts[@]}" -v "$TMP/state:/state:z" --entrypoint healthcheck.sh "$IMAGE"; then
  pass "healthy after exit 0"
else
  fail "unhealthy after exit 0"
fi
printf 'exit=1 time=2026-01-01T00:00:00Z\n' >"$TMP/state/last-run"
if "$ENGINE" run "${run_opts[@]}" "${container_opts[@]}" -v "$TMP/state:/state:z" --entrypoint healthcheck.sh "$IMAGE"; then
  fail "healthy after exit 1"
else
  pass "unhealthy after exit 1"
fi
rm -f "$TMP/state/last-run"

echo "== Internet outage (the catalog cannot be fetched)"
rm -f "$TMP/state/kiwix-index"
out="$("$ENGINE" run "${run_opts[@]}" "${container_opts[@]}" "${offline[@]}" -e RUN_INTERVAL=once -e DRY_RUN=false \
  -e FAKE_WGET_CATALOG_FAIL=1 "$IMAGE" 2>&1)"
status=$?
if [[ $status -eq 1 ]]; then pass "a run without the catalog exits 1"; else fail "outage run exit $status"; echo "$out"; fi
if [[ "$(snapshot)" == "$before" ]]; then pass "ZIM directory unchanged"; else fail "ZIM directory changed"; snapshot; fi
if "$ENGINE" run "${run_opts[@]}" "${container_opts[@]}" -v "$TMP/state:/state:z" --entrypoint healthcheck.sh "$IMAGE"; then
  fail "healthy after the outage"
else
  pass "unhealthy after the outage"
fi
rm -f "$TMP/state/last-run"

echo "== HEALTHCHECK in the image"
hc="$("$ENGINE" image inspect --format '{{json .Config.Healthcheck}}' "$IMAGE" 2>&1)"
if [[ "$hc" == *healthcheck.sh* ]]; then pass "HEALTHCHECK: $hc"; else fail "no HEALTHCHECK in the image: $hc"; fi

echo "== Clean stop of the scheduled loop"
CONTAINER_ID="$("$ENGINE" run -d "${container_opts[@]}" "${offline[@]}" -e RUN_INTERVAL=1h "$IMAGE")"
for _ in $(seq 1 60); do
  [[ -e "$TMP/state/last-run" ]] && break
  sleep 0.5
done
start=$SECONDS
"$ENGINE" stop -t 30 "$CONTAINER_ID" >/dev/null
code="$("$ENGINE" inspect --format '{{.State.ExitCode}}' "$CONTAINER_ID")"
logs="$("$ENGINE" logs "$CONTAINER_ID" 2>&1)"
if [[ "$code" == "0" && $((SECONDS - start)) -lt 20 && "$logs" == *"stopped by SIGTERM"* ]]; then
  pass "stop ends the loop with exit 0 in $((SECONDS - start))s"
else
  fail "stop: exit $code after $((SECONDS - start))s"; echo "$logs" | tail -n 5
fi
if [[ "$(snapshot)" == "$before" ]]; then pass "ZIM directory still unchanged"; else fail "ZIM directory changed"; fi

echo
if [[ $failures -gt 0 ]]; then
  echo "docker-test: $failures check(s) failed"
  exit 1
fi
echo "docker-test: all checks passed"
