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
# and PATH starts with test/helpers/bin, so wget, git, df and kiwix-manage are stubs.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB_BIN="$REPO_ROOT/test/helpers/bin"
FIXTURES_SRC="$REPO_ROOT/test/fixtures"
TEST_LIBS="$REPO_ROOT/test/libs"

# Fixture names (see test/fixtures/catalog.xml). The catalog's current release of each title, an older local
# release, and the path of the current release in the remote tree.
# shellcheck disable=SC2034 # read by the test files, which shellcheck does not see
{
  WP_NEW=wikipedia_en_test_2026-01.zim
  WP_OLD=wikipedia_en_test_2025-12.zim
  WP_REMOTE=zim/wikipedia/$WP_NEW
  WT_NEW=wiktionary_fr_test_2026-02a.zim
  WT_OLD=wiktionary_fr_test_2026-02.zim
  WT_REMOTE=zim/wiktionary/$WT_NEW
}

common_setup() {
  # Every suite uses run --separate-stderr or run's status checks, which need bats 1.5 (else warning BW02)
  bats_require_minimum_version 1.5.0
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
  export FAKE_KIWIX_MANAGE_LOG="$SANDBOX/kiwix-manage.log"
  export FAKE_KIWIX_MANAGE_SEEN="$SANDBOX/kiwix-manage.seen"
  # df stub: plenty of free space unless a test says otherwise (1 TiB)
  export FAKE_DF_AVAIL=1099511627776
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

# Add a catalog entry for a ZIM at the root of the download tree, outside any category (serving a fixture copy).
add_root_level_catalog_entry() {
  [[ "$FAKE_FIXTURES" == "$SANDBOX/fixtures" ]] || use_fixture_copy
  local entry='  <entry>\n    <link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" href="https://download.kiwix.test/zim/rootlevel_test_2026-01.zim.meta4" length="1024" />\n  </entry>'
  sed -i "s#</feed>#$entry\n</feed>#" "$FAKE_FIXTURES/catalog.xml"
}

# Number of ZIMs the served catalog lists.
catalog_zim_count() {
  grep -c 'application/x-zim' "$FAKE_FIXTURES/catalog.xml"
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

# assert_single_download <target> <url> - wget was asked for exactly one download, of <url> into <target>, with -c.
# The network options in front of it are pinned once, in the network test.
assert_single_download() {
  run wget_downloads
  # shellcheck disable=SC2154 # bats' run sets lines and output
  [[ "${#lines[@]}" -eq 1 && "$output" == *" -c -O $1 $2" ]] || fail "expected one download '-c -O $1 $2', got: $output"
}

# The download log the script wrote in the run directory (empty if none).
download_log() {
  cat "$RUN_DIR/download.log" 2>/dev/null || true
}

# make_tooldir [<tool to leave out>...]
# Build $SANDBOX/tools ($TOOLDIR) with symlinks to the real tools the script needs, plus the wget, git, df and
# kiwix-manage stubs, and leave out the named tools. Run the script with PATH="$TOOLDIR" to hide a tool from it.
make_tooldir() {
  local tooldir="$SANDBOX/tools" tool src skip
  local base_path="${PATH#"$STUB_BIN:"}"
  mkdir -p "$tooldir"
  for tool in bash env readlink realpath basename dirname date head tail grep \
    tee uniq wc ls numfmt du sha256sum touch rm mv cp mkdir mktemp cat sleep \
    timeout flock sed awk tr sort stat find cut id uname cmp; do
    for skip in "$@"; do
      [[ "$tool" == "$skip" ]] && continue 2
    done
    src="$(PATH="$base_path" command -v "$tool")" || continue
    ln -s "$src" "$tooldir/$tool"
  done
  for tool in wget git df kiwix-manage; do
    for skip in "$@"; do
      [[ "$tool" == "$skip" ]] && continue 2
    done
    ln -s "$STUB_BIN/$tool" "$tooldir/$tool"
  done
  # shellcheck disable=SC2034 # read by the test files, which shellcheck does not see
  TOOLDIR="$tooldir"
}

# File checks that name the path when they fail:
#   assert_exists <path>     a regular file exists at <path>
#   assert_nonempty <path>   a non-empty regular file exists at <path>
#   refute_exists <path>     nothing exists at <path>
#   refute_nonempty <path>   nothing, or only an empty file, exists at <path>
assert_exists() {
  [[ -f "$1" ]] || fail "expected a file at $1"
}
assert_nonempty() {
  [[ -f "$1" && -s "$1" ]] || fail "expected a non-empty file at $1"
}
refute_exists() {
  [[ ! -e "$1" ]] || fail "expected nothing at $1"
}
refute_nonempty() {
  [[ ! -s "$1" ]] || fail "expected nothing or an empty file at $1: $(head -c 500 "$1")"
}

# wait_until <seconds> <command...> - poll <command> until it succeeds; fail after <seconds>.
wait_until() {
  local timeout="$1" deadline
  shift
  deadline=$((SECONDS + timeout))
  until "$@"; do
    ((SECONDS < deadline)) || fail "gave up after ${timeout}s waiting for: $*"
    sleep 0.1
  done
}

# keep_copy <name> - keep a pristine copy of a file in the ZIM directory, for assert_zim_unchanged after the run.
keep_copy() {
  cp "$ZIMS/$1" "$SANDBOX/$1.orig"
}

# assert_zim_unchanged <name> - the file in the ZIM directory still matches the copy keep_copy made of it.
assert_zim_unchanged() {
  cmp "$ZIMS/$1" "$SANDBOX/$1.orig" || fail "$ZIMS/$1 is missing or changed"
}
