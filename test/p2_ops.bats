#!/usr/bin/env bats
# Operational safeguards: dependency preflight (H7), the cached catalog
# index (H4) and the lock on the ZIM directory (H6).

setup() {
  load 'helpers/common'
  common_setup
}

###############################################################################
# H7: dependency preflight

@test "H7: several missing tools are all named on stderr, before any network access" {
  make_tooldir wget numfmt flock
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater --separate-stderr "$ZIMS"
  assert_failure 1
  [[ "$stderr" == *"wget"* ]]
  [[ "$stderr" == *"numfmt"* ]]
  [[ "$stderr" == *"flock"* ]]
  refute_output --partial 'Building online ZIM list'
}

@test "H7: a grep without -P support is reported" {
  make_tooldir grep
  local real_grep
  real_grep="$(command -v grep)"
  # A grep that refuses -P, like BusyBox or BSD grep.
  cat >"$TOOLDIR/grep" <<EOF
#!$(command -v bash)
for a in "\$@"; do
  [[ "\$a" == -*P* ]] && { echo "grep: invalid option -- 'P'" >&2; exit 2; }
done
exec "$real_grep" "\$@"
EOF
  chmod +x "$TOOLDIR/grep"
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'grep -P'
}

@test "H7: git is required when the self-update would run" {
  make_tooldir git
  mkdir "$SANDBOX/bin/.git"
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater -U "$ZIMS"
  assert_failure 1
  assert_output --partial 'git'
}

@test "H7: git is not required without -U, even in a git clone" {
  make_tooldir git
  mkdir "$SANDBOX/bin/.git"
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater "$ZIMS"
  assert_success
  refute_output --partial 'Missing required tool'
}

@test "H7: git is not required outside a git clone" {
  make_tooldir git
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater -U "$ZIMS"
  assert_success
  refute_output --partial 'Missing required tool'
}

###############################################################################
# H6: one instance per ZIM directory

teardown() {
  # The read-only test removes write permission; give it back so bats can
  # clean up the sandbox even when that test fails.
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
}

@test "H6: a held lock is reported on stderr and creates nothing in the ZIM dir" {
  make_local_zim "$WP_OLD"
  local before
  before="$(zim_dir_snapshot)"
  exec 8<"$ZIMS"
  flock -n 8
  run_updater --separate-stderr -d "$ZIMS"
  exec 8<&-
  assert_failure 75
  [[ "$stderr" == *"already running"* ]]
  refute_output --partial 'Building online ZIM list'
  assert_equal "$(zim_dir_snapshot)" "$before"
  run grep -F opds "$FAKE_WGET_LOG"
  assert_failure
}

@test "H6: a lock on another ZIM dir does not block this one" {
  mkdir "$SANDBOX/other"
  make_local_zim "$WP_OLD"
  exec 8<"$SANDBOX/other"
  flock -n 8
  run_updater "$ZIMS"
  exec 8<&-
  assert_success
}

@test "H6: the lock is released when a run ends, so the next run works" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  run_updater "$ZIMS"
  assert_success
  # and nothing else holds it afterwards
  exec 8<"$ZIMS"
  flock -n 8
  exec 8<&-
}

@test "H6: a dry run on a read-only ZIM dir still works with the lock" {
  [[ $(id -u) -ne 0 ]] || skip "root ignores directory permissions"
  make_local_zim "$WP_OLD"
  chmod a-w "$ZIMS"
  local before
  before="$(zim_dir_snapshot)"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'Building online ZIM list'
  assert_equal "$(zim_dir_snapshot)" "$before"
}

@test "H6: the lock is also taken on a read-only ZIM dir" {
  [[ $(id -u) -ne 0 ]] || skip "root ignores directory permissions"
  make_local_zim "$WP_OLD"
  chmod a-w "$ZIMS"
  exec 8<"$ZIMS"
  flock -n 8
  run_updater -d "$ZIMS"
  exec 8<&-
  assert_failure 75
}

###############################################################################
# H4: the cached catalog index (kiwix-index in the run dir)

INDEX="kiwix-index"

# True if the catalog was requested since the wget log was last cleared.
catalog_fetched() {
  grep -qF opds "$FAKE_WGET_LOG"
}

# Rewrite the date line of the cached index to the given `date -d` string.
age_index() {
  local date
  date="$(date -u -d "$1" +%Y-%m-%dT%H:%M:%S)"
  sed -i "1s/.*/$date/" "$RUN_DIR/$INDEX"
}

@test "H4: the index has the date on its first line and one link line per ZIM" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  run head -1 "$RUN_DIR/$INDEX"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$'
  run tail -n +2 "$RUN_DIR/$INDEX"
  assert_output "$(grep -i 'application/x-zim' "$FAKE_FIXTURES/catalog.xml" | sed 's/^[[:space:]]*//')"
  run ls -A "$RUN_DIR"
  assert_output "$(printf 'download.log\n%s' "$INDEX")"
}

@test "H4: a fresh cached index is reused without fetching the catalog" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  catalog_fetched
  cp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  : >"$FAKE_WGET_LOG"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'Found 4 files online'
  run catalog_fetched
  assert_failure
  cmp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
}

@test "H4: -g fetches the catalog even with a fresh index" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  : >"$FAKE_WGET_LOG"
  run_updater -g "$ZIMS"
  assert_success
  catalog_fetched
}

@test "H4: an index older than a day is refreshed" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  age_index '2 days ago'
  : >"$FAKE_WGET_LOG"
  run_updater "$ZIMS"
  assert_success
  catalog_fetched
  run date -u -d "$(head -1 "$RUN_DIR/$INDEX")" +%s
  ((output > $(date -u -d '1 hour ago' +%s)))
}

@test "H4: a cached index without links is not reused" {
  make_local_zim "$WP_OLD"
  date -u +%Y-%m-%dT%H:%M:%S >"$RUN_DIR/$INDEX"
  run_updater "$ZIMS"
  assert_success
  catalog_fetched
  assert_output --partial 'Found 4 files online'
}

@test "H4: a failed -g refetch exits 1 and leaves the existing index untouched" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  cp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  export FAKE_WGET_CATALOG_FAIL=1
  run_updater -g "$ZIMS"
  assert_failure 1
  assert_output --partial 'Could not fetch the online catalog'
  cmp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  run download_log
  assert_output --partial 'Could not fetch the online catalog'
}

@test "H4: a failed refresh of a stale index exits 1 and leaves it untouched" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  age_index '2 days ago'
  cp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  export FAKE_WGET_CATALOG_FAIL=1
  run_updater "$ZIMS"
  assert_failure 1
  cmp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  run ls -A "$RUN_DIR"
  assert_output "$(printf 'download.log\n%s' "$INDEX")"
}

@test "H4: a catalog without an <updated> date exits 1 and is not cached" {
  use_fixture_copy
  sed -i '/<updated>/d' "$FAKE_FIXTURES/catalog.xml"
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'no <updated> date'
  refute_exists "$RUN_DIR/$INDEX"
}

@test "H4: a catalog without ZIM links exits 1 and does not replace the index" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  cp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  use_fixture_copy
  sed -i '/application\/x-zim/d' "$FAKE_FIXTURES/catalog.xml"
  run_updater -g "$ZIMS"
  assert_failure 1
  assert_output --partial 'No ZIM URLs found'
  cmp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
}
