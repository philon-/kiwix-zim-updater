#!/usr/bin/env bats
# A ZIM directory that cannot be written forces dry-run; with -d that is a failure cron must see.

setup() {
  load 'helpers/common'
  common_setup
  [[ $EUID -ne 0 ]] || skip "root can write to read-only directories"
}

teardown() {
  chmod u+w "$ZIMS" 2>/dev/null || true
}

OLD_WP=wikipedia_en_test_2025-12.zim

@test "N8: -d on a read-only ZIM dir changes nothing and exits 1" {
  make_local_zim "$OLD_WP"
  chmod a-w "$ZIMS"
  local before
  before="$(zim_dir_snapshot)"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_output --partial "Cannot write to '$ZIMS'"
  assert_output --partial 'the ZIM directory is not writable, so nothing was changed'
  assert_equal "$(zim_dir_snapshot)" "$before"
}

@test "N8: a plain dry-run on a read-only ZIM dir still exits 0" {
  make_local_zim "$OLD_WP"
  chmod a-w "$ZIMS"
  run_updater "$ZIMS"
  assert_success
  refute_output --partial 'nothing was changed'
}
