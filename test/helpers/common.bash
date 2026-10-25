# Shared setup for the bats suites. Load it from a test file with:
#
#   setup() {
#     load 'helpers/common'
#     common_setup
#   }
#
# Every test gets its own sandbox under $BATS_TEST_TMPDIR:
#   $SANDBOX/bin   copy of the script (outside any git tree, so self-update
#                  never finds a .git and never touches this repository)
#   $SANDBOX/run   CWD for the run; download.log and kiwix-index land here
#   $SANDBOX/zims  the ZIM directory passed to the script ($ZIMS)
# and PATH starts with test/helpers/bin, so wget, git and clear are stubs.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB_BIN="$REPO_ROOT/test/helpers/bin"
FIXTURES_SRC="$REPO_ROOT/test/fixtures"
TEST_LIBS="$REPO_ROOT/test/libs"

common_setup() {
  load "$TEST_LIBS/bats-support/load"
  load "$TEST_LIBS/bats-assert/load"

  SANDBOX="$BATS_TEST_TMPDIR"
  case "$SANDBOX/" in
    "$REPO_ROOT"/*)
      echo "refusing to run: sandbox $SANDBOX is inside the repository" >&2
      return 1
      ;;
  esac

  RUN_DIR="$SANDBOX/run"
  ZIMS="$SANDBOX/zims"
  SCRIPT_COPY="$SANDBOX/bin/kiwix-zim-updater.sh"
  mkdir -p "$SANDBOX/bin" "$RUN_DIR" "$ZIMS"
  cp "$REPO_ROOT/kiwix-zim-updater.sh" "$SCRIPT_COPY"
  chmod +x "$SCRIPT_COPY"

  # Stub knobs: start from a clean slate whatever the caller's environment.
  unset FAKE_WGET_FAIL FAKE_WGET_NETFAIL FAKE_WGET_SHORT FAKE_WGET_CORRUPT FAKE_WGET_META_FAIL \
    FAKE_WGET_CATALOG_FAIL FAKE_WGET_FLAVOR FAKE_GIT_MODE
  # Globals the script reads without initialising them (finding M4). Unset
  # them so that nothing leaks in from the environment running the tests.
  unset SKIP_PURGE COUNTRY_CODE POSITIONAL_ARGS DownloadFailed IsMirror \
    ExpectedSize ExpectedHash FileName DownloadURL

  export FAKE_FIXTURES="$FIXTURES_SRC"
  export FAKE_WGET_LOG="$SANDBOX/wget.log"
  export FAKE_GIT_LOG="$SANDBOX/git.log"
  export FAKE_CLEAR_LOG="$SANDBOX/clear.log"
  : >"$FAKE_WGET_LOG"
  : >"$FAKE_GIT_LOG"

  export PATH="$STUB_BIN:$PATH"

  cd "$RUN_DIR" || return 1
}

# Copy the fixtures into the sandbox and serve them from there, for tests
# that need to add, change or remove remote files.
use_fixture_copy() {
  cp -r "$FIXTURES_SRC" "$SANDBOX/fixtures"
  export FAKE_FIXTURES="$SANDBOX/fixtures"
}

# Path of a remote fixture file, e.g. remote_file zim/other/small_test_2025-12.zim
remote_file() {
  printf '%s/remote/%s\n' "$FAKE_FIXTURES" "$1"
}

# make_local_zim <name> [<content> | --from-remote <relpath>]
# Create a ZIM in $ZIMS. Without content it gets a short deterministic text.
make_local_zim() {
  local name="$1"
  shift
  if [[ "${1:-}" == "--from-remote" ]]; then
    cp "$(remote_file "$2")" "$ZIMS/$name"
  elif [[ $# -gt 0 ]]; then
    printf '%s' "$1" >"$ZIMS/$name"
  else
    printf 'local zim %s\n' "$name" >"$ZIMS/$name"
  fi
}

# Write a correct "<hash>  <name>" checksum file next to a local ZIM.
make_local_sha256() {
  local name="$1"
  (cd "$ZIMS" && sha256sum "$name" >"$name.sha256")
}

# run_updater [--separate-stderr] <args...>
# Run the sandboxed copy of the script from $RUN_DIR via bats' `run`.
run_updater() {
  local run_opts=()
  if [[ "${1:-}" == "--separate-stderr" ]]; then
    run_opts+=(--separate-stderr)
    shift
  fi
  cd "$RUN_DIR" || return 1
  run "${run_opts[@]}" bash "$SCRIPT_COPY" "$@"
}

# Sorted listing of the ZIM directory: relative path, size, mtime.
zim_dir_snapshot() {
  (cd "$ZIMS" && find . -mindepth 1 -printf '%P %s %T@\n' | LC_ALL=C sort)
}

# Lines of the wget log that write to a file (-O <target> with target != -).
wget_downloads() {
  awk '{ for (i = 1; i < NF; i++) if ($i == "-O" && $(i + 1) != "-") { print; next } }' "$FAKE_WGET_LOG"
}

# The download log the script wrote in the run directory (empty if none).
download_log() {
  cat "$RUN_DIR/download.log" 2>/dev/null || true
}
