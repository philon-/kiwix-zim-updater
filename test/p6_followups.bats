#!/usr/bin/env bats
# Follow-ups after the reviews: size limits on resumes, -f -p size mismatch, checksum files after -c failures.

setup() {
  load 'helpers/common'
  common_setup
}

BIG=big_test_2026-03.zim
BIG_REMOTE=zim/other/big_test_2026-03.zim

@test "checksum files: a download that fails -c leaves no checksum file behind" {
  make_local_zim "$WP_OLD"
  export FAKE_WGET_CORRUPT="$WP_NEW"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  refute_exists "$ZIMS/$WP_NEW"
  refute_exists "$ZIMS/$WP_NEW.sha256"
  assert_exists "$ZIMS/$WP_OLD"
}

@test "checksum files: a download that passes -c gets its checksum file" {
  make_local_zim "$WP_OLD"
  run_updater -d -c "$ZIMS"
  assert_success
  run cat "$ZIMS/$WP_NEW.sha256"
  assert_output "$(cut -d' ' -f1 "$(remote_file "$WP_REMOTE.sha256")") $WP_NEW"
}
