# Shared setup for the container tests, test/docker-smoke.sh and test/library-integration.sh. Set TEST_NAME, then
# source this file. It provides:
#   ENGINE (CONTAINER_ENGINE, or podman/docker found on PATH) and IMAGE, which must exist (make docker-build)
#   user_opts           run a container as the calling user, so files it writes in TMP stay removable
#   TMP                 a temporary directory, removed on exit, with every container in cleanup_containers
#   pass, fail          report a check; fail counts it
#   summary             print the result and exit 1 if a check failed; calls on_failure first, if the test defines it
#   abort <message>     fail, then end the test at once through summary

ENGINE="${CONTAINER_ENGINE:-}"
IMAGE="${IMAGE:-localhost/kiwix-zim-updater:test}"

if [[ -z "$ENGINE" ]]; then
  ENGINE="$(command -v podman || command -v docker)" || {
    echo "$TEST_NAME: neither podman nor docker found" >&2
    exit 1
  }
fi
if ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "$TEST_NAME: no image $IMAGE; build it with make docker-build" >&2
  exit 1
fi

user_opts=(--user "$(id -u):$(id -g)")
# keep-id maps the calling user into the container unchanged
[[ "$(basename "$ENGINE")" == podman* ]] && user_opts+=(--userns=keep-id)

failures=0
pass() { echo "ok   $*"; }
fail() {
  echo "FAIL $*"
  failures=$((failures + 1))
}

summary() {
  echo
  if [[ $failures -gt 0 ]]; then
    declare -F on_failure >/dev/null && on_failure
    echo "$TEST_NAME: $failures check(s) failed"
    exit 1
  fi
  echo "$TEST_NAME: all checks passed"
  exit 0
}

abort() {
  fail "$*"
  summary
}

TMP="$(mktemp -d)"
cleanup_containers=()
cleanup() {
  local container
  for container in "${cleanup_containers[@]}"; do
    "$ENGINE" rm -f "$container" >/dev/null 2>&1
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
