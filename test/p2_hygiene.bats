#!/usr/bin/env bats
# Script hygiene: globals that leak in from the environment (M4), the ZIM
# listing (M1) and the -S option (N4).

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
}

NEW_WP=wikipedia_en_test_2026-01.zim
OLD_WP=wikipedia_en_test_2025-12.zim
WP_REMOTE=zim/wikipedia/wikipedia_en_test_2026-01.zim

###############################################################################
# M4: every global is initialised, so nothing leaks in from the environment.
# common_setup unsets these variables; the tests export them deliberately.

@test "M4: SKIP_PURGE=1 in the environment does not stop -d from purging" {
  make_local_zim "$OLD_WP"
  export SKIP_PURGE=1
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
  [[ ! -e "$ZIMS/$OLD_WP" ]]
}

@test "M4: SKIP_PURGE in the environment is never evaluated as arithmetic" {
  make_local_zim "$OLD_WP"
  export SKIP_PURGE="x[\$(touch '$SANDBOX/pwned')]"
  run_updater -d "$ZIMS"
  assert_success
  [[ ! -e "$SANDBOX/pwned" ]]
}

@test "M4: COUNTRY_CODE in the environment does not reach the meta4 request" {
  make_local_zim "$OLD_WP"
  export COUNTRY_CODE=XX
  run_updater "$ZIMS"
  assert_success
  run grep -c 'meta4?country=$' "$FAKE_WGET_LOG"
  assert_output '1'
  run grep -F 'country=XX' "$FAKE_WGET_LOG"
  assert_output ''
}

@test "M4: POSITIONAL_ARGS in the environment does not replace the ZIM directory" {
  make_local_zim "$OLD_WP"
  export POSITIONAL_ARGS="$SANDBOX/elsewhere"
  run_updater "$ZIMS"
  assert_success
  refute_output --partial 'is not a directory'
  assert_output --partial "- $OLD_WP:"
}
