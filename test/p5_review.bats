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

@test "R10: -f -d -p finishing an interrupted current download prints no 'cannot remove'" {
  head -c 1000 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  run_updater --separate-stderr -f -d -p "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
  [[ "$stderr" != *"cannot remove"* ]]
}

@test "R3: -f -d verifies a locked outdated ZIM against its own checksum and never deletes it" {
  make_local_zim "$WP_OLD"
  make_local_sha256 "$WP_OLD"
  keep_copy "$WP_OLD"
  keep_copy "$WP_OLD.sha256"
  touch "$ZIMS/.~lock.$WP_OLD"
  export FAKE_WGET_FAIL="$WP_NEW"
  run_updater -f -d "$ZIMS"
  assert_success
  assert_output --partial 'Cached Checksum Found'
  assert_output --partial 'Checksum passed'
  assert_zim_unchanged "$WP_OLD"
  assert_zim_unchanged "$WP_OLD.sha256"
  run wget_downloads
  assert_output ''
}

@test "R3: -f -d -p never rewrites a locked outdated ZIM's cached checksum with the newer release's hash" {
  make_local_zim "$WP_OLD"
  make_local_sha256 "$WP_OLD"
  keep_copy "$WP_OLD.sha256"
  touch "$ZIMS/.~lock.$WP_OLD"
  run_updater -f -d -p "$ZIMS"
  assert_zim_unchanged "$WP_OLD.sha256"
  assert_exists "$ZIMS/$WP_OLD"
}

@test "R5: -f -d does not resume an update download for an outdated ZIM it checks by cached checksum" {
  make_local_zim "$WP_OLD"
  make_local_sha256 "$WP_OLD"
  head -c 1000 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  keep_copy "$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  run_updater -f -d "$ZIMS"
  assert_success
  refute_output --partial 'resuming'
  refute_output --partial 'removing corrupt file'
  assert_zim_unchanged "$WP_NEW"
  assert_exists "$ZIMS/.~lock.$WP_NEW"
  run wget_downloads
  assert_output ''
}

@test "R5: -f -d still finishes an interrupted download of the current catalog version" {
  head -c 1000 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  run_updater -f -d "$ZIMS"
  assert_success
  assert_output --partial 'Incomplete download detected, resuming'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
}

@test "R7: dry-run -f exits 1 for a truncated current ZIM, like for a corrupt outdated one" {
  make_local_zim "$WP_NEW" "truncated"
  run_updater -f "$ZIMS"
  assert_failure 1
  assert_output --partial 'File size verification failed'
}

@test "R7: dry-run -f -p says the purge would be skipped, not that it removes the file" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  run_updater -f -p "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed but purge skipped'
  refute_output --partial 'removing corrupt file'
}

@test "R9: -f verifies a current ZIM offline against its cached checksum" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_sha256 "$WP_NEW"
  # Run once online so the catalog index is cached, then go "offline"
  run_updater -f "$ZIMS"
  assert_success
  export FAKE_WGET_META_FAIL=1 FAKE_WGET_CATALOG_FAIL=1
  run_updater -f "$ZIMS"
  assert_success
  assert_output --partial 'verifying against the cached checksum'
  assert_output --partial 'Checksum passed'
}

@test "R9: offline -f still detects a corrupt current ZIM through its cached checksum" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_sha256 "$WP_NEW"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  export FAKE_WGET_META_FAIL=1
  run_updater -f "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed'
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

@test "N12: offline -f -d keeps a current ZIM that fails its cached checksum (no replacement can be verified)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_sha256 "$WP_NEW"
  run_updater -f "$ZIMS"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  keep_copy "$WP_NEW"
  keep_copy "$WP_NEW.sha256"
  : >"$FAKE_WGET_LOG"
  export FAKE_WGET_META_FAIL=1 FAKE_WGET_CATALOG_FAIL=1
  run_updater -f -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed against the cached checksum. File kept'
  assert_zim_unchanged "$WP_NEW"
  assert_zim_unchanged "$WP_NEW.sha256"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
  run wget_downloads
  assert_output ''
}

@test "N12: with only the meta4 down, -f -d keeps the ZIM instead of starting an unverifiable download" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_sha256 "$WP_NEW"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  keep_copy "$WP_NEW"
  export FAKE_WGET_META_FAIL=1
  run_updater -f -d "$ZIMS"
  assert_failure 1
  assert_zim_unchanged "$WP_NEW"
  run wget_downloads
  assert_output ''
}
