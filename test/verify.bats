#!/usr/bin/env bats
# Characterization: -f / --verify-library.

setup() {
  load 'helpers/common'
  common_setup
}

CUR_WP=wikipedia_en_test_2026-01.zim
WP_REMOTE=zim/wikipedia/wikipedia_en_test_2026-01.zim

@test "verify: -f -d passes an intact current ZIM and leaves it alone" {
  make_local_zim "$CUR_WP" --from-remote "$WP_REMOTE"
  run_updater -f -d "$ZIMS"
  assert_success
  assert_output --partial 'Online Version Found'
  assert_output --partial "Calculating checksum for : $CUR_WP"
  assert_output --partial 'Status : Checksum passed'
  refute_output --partial 'Checksum failed'
  cmp "$ZIMS/$CUR_WP" "$(remote_file "$WP_REMOTE")"
  run wget_downloads
  assert_output ''
}

@test "verify: -f reports a corrupted current ZIM (dry-run)" {
  make_local_zim "$CUR_WP" --from-remote "$WP_REMOTE"
  # Same size, one byte different.
  printf 'X' | dd of="$ZIMS/$CUR_WP" bs=1 seek=10 conv=notrunc status=none
  run_updater -f "$ZIMS"
  # The corrupt file stays (dry-run), so the verification failed: exit 1 (R7)
  assert_failure 1
  assert_output --partial '*** Simulated *** Checksum failed, removing corrupt file'
  [[ -f "$ZIMS/$CUR_WP" ]]
  run wget_downloads
  assert_output ''
}

@test "verify: -f reports a truncated current ZIM as a size failure (dry-run)" {
  head -c 100 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$CUR_WP"
  run_updater -f "$ZIMS"
  # The truncated file stays (dry-run), so the verification failed: exit 1 (R7)
  assert_failure 1
  assert_output --partial '*** Simulated *** File size verification failed, removing corrupt file'
  [[ -f "$ZIMS/$CUR_WP" ]]
}

@test "verify: -f uses a cached .sha256 for an outdated ZIM and changes nothing" {
  make_local_zim wikipedia_en_test_2025-12.zim
  make_local_sha256 wikipedia_en_test_2025-12.zim
  local before
  before="$(zim_dir_snapshot)"
  run_updater -f "$ZIMS"
  assert_success
  assert_output --partial 'Cached Checksum Found'
  assert_output --partial 'Status : Checksum passed'
  [[ "$(zim_dir_snapshot)" == "$before" ]]
}

@test "verify: -f with an outdated ZIM and no checksum anywhere skips it" {
  make_local_zim wikipedia_en_test_2025-12.zim
  run_updater -f "$ZIMS"
  assert_success
  assert_output --partial 'Checking for online checksum...'
  assert_output --partial 'Online Version Not Found'
  run grep -c -- '--spider' "$FAKE_WGET_LOG"
  assert_output '1'
}

@test "verify: -f honours -n/-x and skips verification by size" {
  make_local_zim small_test_2025-12.zim --from-remote zim/other/small_test_2025-12.zim
  run_updater -f -n 2K "$ZIMS"
  assert_success
  assert_output --partial 'Verification skipped due to file size (minimum'
}
