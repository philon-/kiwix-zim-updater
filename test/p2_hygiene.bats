#!/usr/bin/env bats
# Script hygiene: globals that leak in from the environment (M4), the ZIM
# listing (M1) and the -S option (N4).

setup() {
  load 'helpers/common'
  common_setup
}

###############################################################################
# M4: every global is initialised, so nothing leaks in from the environment.
# common_setup unsets these variables; the tests export them deliberately.

###############################################################################
# M1: the ZIM directory is listed with a glob, not by parsing ls.

###############################################################################
# N4: -S/--no-sha stops new .sha256 files from being written.

@test "N4: -f -d -S still verifies the library but writes no .sha256" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater -f -d -S "$ZIMS"
  assert_success
  assert_output --partial 'Checksum passed'
  refute_exists "$ZIMS/$WP_NEW.sha256"
  run find "$ZIMS" -name '*.sha256*'
  assert_output ''
}

@test "N4: -f -d -S still detects and replaces a corrupt ZIM" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  run_updater -f -d -S "$ZIMS"
  assert_output --partial 'Checksum failed, downloading a replacement'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  run find "$ZIMS" -name '*.sha256*'
  assert_output ''
}

###############################################################################
# N: new defects found while working on this file
