#!/usr/bin/env bats
# Known-bug tests. Each one asserts the CORRECT behaviour for a finding of
# the review (F*, H*, M*) or for a defect found while writing the harness
# (N*), and is skipped until the fix lands. The fix commit removes the skip.
#
# Count the open findings with: grep -c 'skip "[FHMN][0-9]' test/*.bats

setup() {
  load 'helpers/common'
  common_setup
}

###############################################################################
# F: data safety

###############################################################################
# H: correctness and operations

@test "H1: a nonexistent ZIM directory exits 2" {
  run_updater "$SANDBOX/does-not-exist"
  assert_failure 2
  assert_output --partial 'is not a directory'
}

@test "H1: a missing ZIM directory argument exits 2" {
  run_updater
  assert_failure 2
  assert_output --partial 'Kiwix ZIM Directory not provided'
}

@test "H2: -c together with -t aborts with exit 2" {
  make_local_zim "$WP_OLD"
  run_updater -d -c -t "$ZIMS"
  assert_failure 2
  assert_output --partial 'Calculating Checksum not available with torrenting'
  run wget_downloads
  assert_output ''
}

@test "H5: -n without a value exits 2" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS" -n
  assert_failure 2
}

@test "H5: -n with a garbage value exits 2" {
  make_local_zim "$WP_OLD"
  run_updater -n banana "$ZIMS"
  assert_failure 2
}

@test "H5: -x with a garbage value exits 2" {
  make_local_zim "$WP_OLD"
  run_updater -x 12parsecs "$ZIMS"
  assert_failure 2
}

@test "H5: an unknown --option exits 2 with usage" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS" --bogus
  assert_failure 2
  assert_output --partial 'Usage:'
}

@test "H5: two positional arguments exit 2" {
  mkdir "$SANDBOX/other"
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS" "$SANDBOX/other"
  assert_failure 2
}

###############################################################################
# M: medium

###############################################################################
# N: new defects found while building the harness (not in the review table)
