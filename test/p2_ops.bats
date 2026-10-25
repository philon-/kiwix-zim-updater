#!/usr/bin/env bats
# Operational safeguards: dependency preflight (H7), the cached catalog
# index (H4) and the lock on the ZIM directory (H6).

setup() {
  load 'helpers/common'
  common_setup
}

###############################################################################
# H7: dependency preflight

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
