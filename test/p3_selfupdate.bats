#!/usr/bin/env bats
# H8: self-update is opt-in (-U) and never touches a clone it should not.

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
}

OLD_WP=wikipedia_en_test_2025-12.zim

###############################################################################
# Opt-in

@test "H8: a default run makes no git call, even next to a .git" {
  mkdir "$SANDBOX/bin/.git"
  export FAKE_GIT_MODE=current
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '1. Checking for Script Updates...'
  assert_output --partial 'Check Skipped (use -U to enable)'
  run cat "$FAKE_GIT_LOG"
  assert_output ''
}

@test "H8: -u and --skip-update are still accepted and run no git" {
  mkdir "$SANDBOX/bin/.git"
  make_local_zim "$OLD_WP"
  run_updater -u "$ZIMS"
  assert_success
  run_updater --skip-update "$ZIMS"
  assert_success
  run cat "$FAKE_GIT_LOG"
  assert_output ''
}

@test "H8: the usage documents -U and the -u compatibility no-op" {
  run_updater -h
  assert_success
  assert_line '    -U, --self-update          Updates this script from its git clone before running (off by default).'
  assert_line '    -u, --skip-update          Accepted for compatibility; self-update is now off unless -U is given.'
}

@test "H8: -U outside a git clone skips the update with a message" {
  make_local_zim "$OLD_WP"
  run_updater -U "$ZIMS"
  assert_success
  assert_output --partial 'Git Clone Not Detected: Skipping Update Check'
  run cat "$FAKE_GIT_LOG"
  assert_output ''
}

@test "H8: --self-update on another branch skips the update" {
  mkdir "$SANDBOX/bin/.git"
  export FAKE_GIT_MODE=other-branch
  make_local_zim "$OLD_WP"
  run_updater --self-update "$ZIMS"
  assert_success
  assert_output --partial 'You appear to be on a different branch'
  run cat "$FAKE_GIT_LOG"
  assert_output --partial 'rev-parse --abbrev-ref HEAD'
  refute_output --partial 'fetch'
  refute_output --partial 'pull'
}
