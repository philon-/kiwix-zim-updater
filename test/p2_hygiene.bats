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

###############################################################################
# M1: the ZIM directory is listed with a glob, not by parsing ls.

@test "M1: a ZIM name with spaces is listed as one ZIM" {
  make_local_zim "$OLD_WP"
  make_local_zim 'my notes_test_2025-01.zim'
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '✗ my notes_test_2025-01.zim  No online match found.'
  assert_output --partial "✓ $OLD_WP  [wikipedia]"
  assert_output --partial '2 ZIM(s) found.'
}

@test "M1: an upper-case .ZIM extension is still found and matched" {
  make_local_zim wikipedia_en_test_2025-12.ZIM
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '✓ wikipedia_en_test_2025-12.ZIM  [wikipedia]'
  assert_output --partial '1 ZIM(s) found.'
}

@test "M1: a directory named like a ZIM is ignored" {
  make_local_zim "$OLD_WP"
  mkdir "$ZIMS/x.zim" "$ZIMS/wiktionary_fr_test_2026-02.zim"
  run_updater "$ZIMS"
  assert_success
  refute_output --partial 'x.zim'
  refute_output --partial 'wiktionary_fr_test_2026-02.zim'
  assert_output --partial '1 ZIM(s) found.'
}

@test "M1: QUOTING_STYLE in the environment does not hide the ZIMs" {
  make_local_zim "$OLD_WP"
  export QUOTING_STYLE=shell-always
  run_updater "$ZIMS"
  assert_success
  assert_output --partial "- $OLD_WP:"
  assert_output --partial 'Update found!'
}

@test "M1: a ZIM name containing a newline is left alone" {
  make_local_zim $'notes\nwikipedia_en_test_2025-12.zim' 'my notes'
  make_local_zim small_test_2025-12.zim --from-remote zim/other/small_test_2025-12.zim
  run_updater -d "$ZIMS"
  assert_success
  run cat "$ZIMS/"$'notes\nwikipedia_en_test_2025-12.zim'
  assert_output 'my notes'
  run wget_downloads
  assert_output ''
}

###############################################################################
# N4: -S/--no-sha stops new .sha256 files from being written.

@test "N4: -f -d -S still verifies the library but writes no .sha256" {
  make_local_zim "$NEW_WP" --from-remote "$WP_REMOTE"
  run_updater -f -d -S "$ZIMS"
  assert_success
  assert_output --partial 'Checksum passed'
  [[ ! -e "$ZIMS/$NEW_WP.sha256" ]]
  run find "$ZIMS" -name '*.sha256*'
  assert_output ''
}

@test "N4: -f -d -S still detects and replaces a corrupt ZIM" {
  make_local_zim "$NEW_WP" --from-remote "$WP_REMOTE"
  printf 'X' | dd of="$ZIMS/$NEW_WP" bs=1 seek=10 conv=notrunc status=none
  run_updater -f -d -S "$ZIMS"
  assert_output --partial 'Checksum failed, downloading a replacement'
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
  run find "$ZIMS" -name '*.sha256*'
  assert_output ''
}

###############################################################################
# N: new defects found while working on this file

@test "N6c: a local ZIM whose name only ends in a catalog basename is not treated as that ZIM" {
  make_local_zim 'my notes+wikipedia_en_test_2025-12.zim' 'my notes'
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial '✗ my notes+wikipedia_en_test_2025-12.zim  No online match found.'
  run cat "$ZIMS/my notes+wikipedia_en_test_2025-12.zim"
  assert_output 'my notes'
  run wget_downloads
  assert_output ''
}
