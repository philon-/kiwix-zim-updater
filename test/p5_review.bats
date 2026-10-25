#!/usr/bin/env bats
# Regression tests for the findings of the independent review (Phase 5, R1-R10).

setup() {
  load 'helpers/common'
  common_setup
}

@test "R4: -c keeps the old ZIM when the metadata has no sha256 to check the download against" {
  use_fixture_copy
  sed -i '/sha-256/d' "$(remote_file "$WP_REMOTE.meta4")"
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  assert_output --partial "No valid sha256 published for $WP_NEW"
  refute_output --partial 'Old ZIM purged'
  assert_zim_unchanged "$WP_OLD"
}

@test "R4: dry-run -c without a published sha256 only reports it" {
  use_fixture_copy
  sed -i '/sha-256/d' "$(remote_file "$WP_REMOTE.meta4")"
  make_local_zim "$WP_OLD"
  run_updater -c "$ZIMS"
  assert_success
  assert_output --partial 'the checksum could not be verified'
}

@test "wget2: downloads also carry --no-metalink, so -O is always honoured" {
  export FAKE_WGET_FLAVOR=wget2
  make_local_zim "$WP_OLD"
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  run wget_downloads
  assert_output --partial -- '--no-metalink'
  run bash -c 'grep -e " -O " "$1" | grep -v -e " -O - " | grep -v -e --no-metalink' _ "$FAKE_WGET_LOG"
  assert_output ''
}
