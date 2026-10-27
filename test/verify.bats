#!/usr/bin/env bats
# -f/--verify-library: checking the local ZIMs against their published or cached checksums, replacing a corrupt
# one only by a verified download, and -S.

setup() {
  load 'helpers/common'
  common_setup
}

###############################################################################
# Current ZIMs

@test "-f -d passes an intact current ZIM and leaves it alone (N6a)" {
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

@test "-f reports a corrupted current ZIM (dry-run)" {
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

@test "-f reports a truncated current ZIM as a size failure (dry-run) (R7)" {
  head -c 100 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  run_updater -f "$ZIMS"
  # The truncated file stays (dry-run), so the verification failed: exit 1 (R7)
  assert_failure 1
  assert_output --partial '*** Simulated *** File size verification failed, a replacement would be downloaded'
  assert_exists "$ZIMS/$WP_NEW"
}

@test "dry-run -f -p says the purge would be skipped, not that it removes the file (R7)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  run_updater -f -p "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed but purge skipped'
  refute_output --partial 'removing corrupt file'
}

@test "-f -d -p: a truncated current ZIM is reported and kept, without a download-failed report" {
  head -c 100 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  keep_copy "$WP_NEW"
  run_updater -f -d -p "$ZIMS"
  assert_failure 1
  assert_output --partial 'File size verification failed but purge skipped'
  refute_output --partial 'One or more downloads failed'
  assert_zim_unchanged "$WP_NEW"
  run wget_downloads
  assert_output ''
  run download_log
  refute_line ' !!! DOWNLOAD FAILED !!!'
}

@test "-f -p dry-run: a truncated current ZIM is reported, nothing is simulated as downloaded" {
  head -c 100 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  run_updater -f -p "$ZIMS"
  assert_failure 1
  assert_output --partial 'Simulated *** File size verification failed but purge skipped'
  refute_output --partial 'Download (mirror)'
  refute_output --partial 'Download (direct)'
}

@test "a checksum failure leaves no 0-byte ZIM behind (F3)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  export FAKE_WGET_CORRUPT="$WP_NEW"
  run_updater -f -d "$ZIMS"
  run find "$ZIMS" -type f -empty
  assert_output ''
}

@test "-f -d -p finishing an interrupted current download prints no 'cannot remove' (R10)" {
  head -c 1000 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  run_updater --separate-stderr -f -d -p "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
  [[ "$stderr" != *"cannot remove"* ]]
}

@test "-f -d does not resume an update download for an outdated ZIM it checks by cached checksum (R5)" {
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

@test "-f -d still finishes an interrupted download of the current catalog version (R5)" {
  head -c 1000 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  run_updater -f -d "$ZIMS"
  assert_success
  assert_output --partial 'Incomplete download detected, resuming'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
}

###############################################################################
# Without metadata: the cached checksum, or nothing at all

@test "-f -d with a failed meta4 fetch keeps a good ZIM and its cached .sha256 (F4, N3)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_sha256 "$WP_NEW"
  keep_copy "$WP_NEW.sha256"
  export FAKE_WGET_META_FAIL=1
  run_updater -f -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  assert_zim_unchanged "$WP_NEW.sha256"
  # Since R9 the cached .sha256 is used when the metadata is unavailable
  assert_output --partial 'verifying against the cached checksum'
  assert_output --partial 'Checksum passed'
}

@test "-f in dry-run writes no .sha256 into the ZIM dir (F4)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  local before
  before="$(zim_dir_snapshot)"
  run_updater -f "$ZIMS"
  assert_success
  assert_equal "$(zim_dir_snapshot)" "$before"
}

@test "-f -d with a failed meta4 fetch and no cached checksum keeps the ZIM and reports it (N3)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  export FAKE_WGET_META_FAIL=1
  run_updater -f -d "$ZIMS"
  assert_failure 1
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  assert_output --partial "cannot verify $WP_NEW"
  refute_output --partial 'Checksum passed'
}

@test "-f exits 1 when a ZIM cannot be verified (metadata unavailable) (N6a)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  export FAKE_WGET_META_FAIL=1
  run_updater -f "$ZIMS"
  assert_failure 1
  assert_output --partial 'cannot verify'
}

@test "-f verifies a current ZIM offline against its cached checksum (R9)" {
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

@test "offline -f still detects a corrupt current ZIM through its cached checksum (R9)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_sha256 "$WP_NEW"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  export FAKE_WGET_META_FAIL=1
  run_updater -f "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed'
}

@test "offline -f -d keeps a current ZIM that fails its cached checksum (no replacement can be verified) (N12)" {
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

@test "with only the meta4 down, -f -d keeps the ZIM instead of starting an unverifiable download (N12)" {
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

###############################################################################
# Outdated ZIMs: checked against their own checksum, never replaced by -f

@test "-f uses a cached .sha256 for an outdated ZIM and changes nothing" {
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

@test "-f with an outdated ZIM and no checksum anywhere keeps it but exits 1" {
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

@test "-f checks an outdated ZIM against its own online checksum, not the new release's (N5)" {
  use_fixture_copy
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  # The older release's checksum is still published next to the new one.
  (cd "$ZIMS" && sha256sum "$WP_OLD") >"$(remote_file "zim/wikipedia/$WP_OLD.sha256")"
  run_updater -f -d "$ZIMS"
  assert_zim_unchanged "$WP_OLD"
  refute_output --partial 'removing corrupt file'
}

@test "-f reports a corrupt outdated ZIM against its own online checksum and keeps it (N5)" {
  use_fixture_copy
  make_local_zim "$WP_OLD"
  (cd "$ZIMS" && sha256sum "$WP_OLD") >"$(remote_file "zim/wikipedia/$WP_OLD.sha256")"
  printf 'tampered' >>"$ZIMS/$WP_OLD"
  keep_copy "$WP_OLD"
  run_updater -f -d "$ZIMS"
  assert_output --partial 'a normal update run (without -f) will replace it'
  assert_zim_unchanged "$WP_OLD"
  run wget_downloads
  assert_output ''
}

@test "-f -d stores the outdated ZIM's own online checksum for offline use (N5)" {
  use_fixture_copy
  make_local_zim "$WP_OLD"
  (cd "$ZIMS" && sha256sum "$WP_OLD") >"$(remote_file "zim/wikipedia/$WP_OLD.sha256")"
  run_updater -f -d "$ZIMS"
  assert_output --partial 'Checksum passed'
  run cat "$ZIMS/$WP_OLD.sha256"
  assert_output "$(cut -d' ' -f1 "$(remote_file "zim/wikipedia/$WP_OLD.sha256")") $WP_OLD"
}

@test "-f -d verifies a locked outdated ZIM against its own checksum and never deletes it (R3)" {
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

@test "-f -d -p never rewrites a locked outdated ZIM's cached checksum with the newer release's hash (R3)" {
  make_local_zim "$WP_OLD"
  make_local_sha256 "$WP_OLD"
  keep_copy "$WP_OLD.sha256"
  touch "$ZIMS/.~lock.$WP_OLD"
  run_updater -f -d -p "$ZIMS"
  assert_zim_unchanged "$WP_OLD.sha256"
  assert_exists "$ZIMS/$WP_OLD"
}

###############################################################################
# ZIMs outside the catalog

@test "-f verifies an unmatched local ZIM against its own .sha256 in the ZIM dir (F6)" {
  make_local_zim orphan_test_2025-01.zim
  make_local_sha256 orphan_test_2025-01.zim
  run_updater -f "$ZIMS"
  assert_success
  assert_output --partial '- orphan_test_2025-01.zim:'
  assert_output --partial 'Cached Checksum Found'
}

@test "-f -d never deletes an unmatched ZIM that has a valid own checksum (N2)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_zim zzz_orphan_test_2025-01.zim "$(head -c 2048 < <(yes 'orphan payload'))"
  make_local_sha256 zzz_orphan_test_2025-01.zim
  keep_copy "zzz_orphan_test_2025-01.zim"
  run_updater -f -d "$ZIMS"
  assert_zim_unchanged "zzz_orphan_test_2025-01.zim"
  assert_output --partial 'Checksum passed'
  run wget_downloads
  assert_output ''
}

@test "-f -d reports a corrupt unmatched ZIM, keeps it and exits 1 (N2, N6a)" {
  make_local_zim orphan_test_2025-01.zim 'orphan payload'
  make_local_sha256 orphan_test_2025-01.zim
  printf 'tampered' >"$ZIMS/orphan_test_2025-01.zim"
  keep_copy "orphan_test_2025-01.zim"
  keep_copy "orphan_test_2025-01.zim.sha256"
  run_updater -f -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed, but no online version to replace it with'
  assert_zim_unchanged "orphan_test_2025-01.zim"
  assert_zim_unchanged "orphan_test_2025-01.zim.sha256"
  run wget_downloads
  assert_output ''
}

@test "-f reports a ZIM outside the catalog without a cached checksum as not checked" {
  make_local_zim my_own_notes_2025-01.zim 'self-made'
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater -f "$ZIMS"
  assert_success
  assert_output --partial '- my_own_notes_2025-01.zim:'
  assert_output --partial 'Not in the catalog and no cached .sha256: not checked by -f'
  run download_log
  assert_line 'Not checked by -f: my_own_notes_2025-01.zim (not in the catalog, no cached .sha256)'
}

###############################################################################
# -n/-x and -S

@test "-f honours -n/-x and skips verification by size" {
  make_local_zim small_test_2025-12.zim --from-remote zim/other/small_test_2025-12.zim
  run_updater -f -n 2K "$ZIMS"
  assert_success
  assert_output --partial 'Verification skipped due to file size (minimum'
}

@test "-S stops new .sha256 files from being written (N4)" {
  make_local_zim "$WP_OLD"
  run_updater -d -S "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_NEW.sha256"
}

@test "-f -d -S still verifies the library but writes no .sha256 (N4)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater -f -d -S "$ZIMS"
  assert_success
  assert_output --partial 'Checksum passed'
  refute_exists "$ZIMS/$WP_NEW.sha256"
  run find "$ZIMS" -name '*.sha256*'
  assert_output ''
}

@test "-f -d -S still detects and replaces a corrupt ZIM (N4)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  run_updater -f -d -S "$ZIMS"
  assert_output --partial 'Checksum failed, downloading a replacement'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  run find "$ZIMS" -name '*.sha256*'
  assert_output ''
}
