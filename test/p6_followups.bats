#!/usr/bin/env bats
# Follow-ups after the reviews: size limits on resumes, -f -p size mismatch, checksum files after -c failures.

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
}

BIG=big_test_2026-03.zim
BIG_REMOTE=zim/other/big_test_2026-03.zim
W=wikipedia_en_test_2026-01.zim
WOLD=wikipedia_en_test_2025-01.zim
WREMOTE=zim/wikipedia/wikipedia_en_test_2026-01.zim

@test "size limits: a locked partial bigger than -x is neither resumed nor deleted" {
  head -c 1000 "$(remote_file "$BIG_REMOTE")" >"$ZIMS/$BIG"
  cp "$ZIMS/$BIG" "$SANDBOX/partial.orig"
  touch "$ZIMS/.~lock.$BIG"
  run_updater -d -x 2Ki "$ZIMS"
  assert_success
  assert_output --partial 'outside the -n/-x size limits. Left as it is.'
  cmp "$ZIMS/$BIG" "$SANDBOX/partial.orig"
  [[ -f "$ZIMS/.~lock.$BIG" ]]
  run wget_downloads
  assert_output ''
}

@test "size limits: a locked partial smaller than -n is left alone, a later run without -n resumes it" {
  head -c 1000 "$(remote_file "$BIG_REMOTE")" >"$ZIMS/$BIG"
  touch "$ZIMS/.~lock.$BIG"
  run_updater -d -n 1Mi "$ZIMS"
  assert_success
  run wget_downloads
  assert_output ''
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$BIG" "$(remote_file "$BIG_REMOTE")"
  [[ ! -e "$ZIMS/.~lock.$BIG" ]]
}

@test "-f -d -p: a truncated current ZIM is reported and kept, without a download-failed report" {
  head -c 100 "$(remote_file "$WREMOTE")" >"$ZIMS/$W"
  cp "$ZIMS/$W" "$SANDBOX/orig"
  run_updater -f -d -p "$ZIMS"
  assert_failure 1
  assert_output --partial 'File size verification failed but purge skipped'
  refute_output --partial 'One or more downloads failed'
  cmp "$ZIMS/$W" "$SANDBOX/orig"
  run wget_downloads
  assert_output ''
  run download_log
  refute_line ' !!! DOWNLOAD FAILED !!!'
}

@test "-f -p dry-run: a truncated current ZIM is reported, nothing is simulated as downloaded" {
  head -c 100 "$(remote_file "$WREMOTE")" >"$ZIMS/$W"
  run_updater -f -p "$ZIMS"
  assert_failure 1
  assert_output --partial 'Simulated *** File size verification failed but purge skipped'
  refute_output --partial 'Download (mirror)'
  refute_output --partial 'Download (direct)'
}
