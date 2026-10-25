#!/usr/bin/env bats
# Characterization: -f / --verify-library.

setup() {
  load 'helpers/common'
  common_setup
}

@test "verify: -f -d passes an intact current ZIM and leaves it alone" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater -f -d "$ZIMS"
  assert_success
  assert_output --partial 'Online Version Found'
  assert_output --partial "Calculating checksum for : $WP_NEW"
  assert_output --partial 'Status : Checksum passed'
  refute_output --partial 'Checksum failed'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  run wget_downloads
  assert_output ''
}

@test "verify: -f reports a corrupted current ZIM (dry-run)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  # Same size, one byte different.
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  run_updater -f "$ZIMS"
  # The corrupt file stays (dry-run), so the verification failed: exit 1 (R7)
  assert_failure 1
  assert_output --partial '*** Simulated *** Checksum failed, a replacement would be downloaded'
  assert_exists "$ZIMS/$WP_NEW"
  run wget_downloads
  assert_output ''
}

@test "verify: -f reports a truncated current ZIM as a size failure (dry-run)" {
  head -c 100 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  run_updater -f "$ZIMS"
  # The truncated file stays (dry-run), so the verification failed: exit 1 (R7)
  assert_failure 1
  assert_output --partial '*** Simulated *** File size verification failed, a replacement would be downloaded'
  assert_exists "$ZIMS/$WP_NEW"
}

@test "verify: -f uses a cached .sha256 for an outdated ZIM and changes nothing" {
  make_local_zim "$WP_OLD"
  make_local_sha256 "$WP_OLD"
  local before
  before="$(zim_dir_snapshot)"
  run_updater -f "$ZIMS"
  assert_success
  assert_output --partial 'Cached Checksum Found'
  assert_output --partial 'Status : Checksum passed'
  [[ "$(zim_dir_snapshot)" == "$before" ]]
}

@test "verify: -f with an outdated ZIM and no checksum anywhere keeps it but exits 1" {
  make_local_zim "$WP_OLD"
  local before
  before="$(zim_dir_snapshot)"
  run_updater -f "$ZIMS"
  # It could not be verified: exit 1 per the exit-code contract (reported by Copilot on PR #1)
  assert_failure 1
  assert_output --partial 'Checking for online checksum...'
  assert_output --partial 'Online Version Not Found'
  assert_output --partial 'it cannot be verified. Kept'
  assert_equal "$(zim_dir_snapshot)" "$before"
  run grep -c -- '--spider' "$FAKE_WGET_LOG"
  assert_output '1'
}

@test "verify: -f honours -n/-x and skips verification by size" {
  make_local_zim small_test_2025-12.zim --from-remote zim/other/small_test_2025-12.zim
  run_updater -f -n 2K "$ZIMS"
  assert_success
  assert_output --partial 'Verification skipped due to file size (minimum'
}

@test "verify: -f reports a ZIM outside the catalog without a cached checksum as not checked" {
  make_local_zim my_own_notes_2025-01.zim 'self-made'
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater -f "$ZIMS"
  assert_success
  assert_output --partial '- my_own_notes_2025-01.zim:'
  assert_output --partial 'Not in the catalog and no cached .sha256: not checked by -f'
  run download_log
  assert_line 'Not checked by -f: my_own_notes_2025-01.zim (not in the catalog, no cached .sha256)'
}
