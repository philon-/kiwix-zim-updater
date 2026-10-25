#!/usr/bin/env bats
# Phase 2: command line parsing and the exit-code contract (H1, H2, H5).
# 0 = ok or nothing to update, 1 = runtime error, 2 = usage error.

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
}

NEW_WP=wikipedia_en_test_2026-01.zim
OLD_WP=wikipedia_en_test_2025-12.zim
WP_REMOTE=zim/wikipedia/wikipedia_en_test_2026-01.zim

###############################################################################
# usage errors (exit 2)

@test "p2-cli: -h prints usage on stdout and exits 0" {
  run_updater --separate-stderr -h
  assert_success
  assert_line --index 0 'Usage: ./kiwix-zim-updater.sh <options> /full/path/'
  assert_equal "$stderr" ''
}

@test "p2-cli: a bad ZIM directory prints usage on stderr, not stdout" {
  run_updater --separate-stderr "$SANDBOX/does-not-exist"
  assert_failure 2
  [[ "$stderr" == *'Usage: ./kiwix-zim-updater.sh'* ]]
  refute_output --partial 'Usage:'
}

@test "p2-cli: a file instead of a ZIM directory exits 2" {
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS/$OLD_WP"
  assert_failure 2
  assert_output --partial 'is not a directory'
}

###############################################################################
# runtime results (exit 0 / 1)

@test "p2-cli: a successful update exits 0" {
  make_local_zim "$OLD_WP"
  run_updater -d -c "$ZIMS"
  assert_success
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
  [[ ! -e "$ZIMS/$OLD_WP" ]]
}

@test "p2-cli: nothing to update exits 0" {
  make_local_zim "$NEW_WP" --from-remote "$WP_REMOTE"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial 'Nothing to download'
}

@test "p2-cli: after a failed download the next ZIM is still processed, then exit 1" {
  make_local_zim "$OLD_WP"
  make_local_zim wiktionary_fr_test_2026-02.zim
  export FAKE_WGET_FAIL=wikipedia_en_test_2026-01
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'One or more downloads failed'
  [[ -f "$ZIMS/$OLD_WP" ]]
  cmp "$ZIMS/wiktionary_fr_test_2026-02a.zim" "$(remote_file zim/wiktionary/wiktionary_fr_test_2026-02a.zim)"
  [[ ! -e "$ZIMS/wiktionary_fr_test_2026-02.zim" ]]
}

@test "p2-cli: a failed torrent download exits 1" {
  make_local_zim "$OLD_WP"
  export FAKE_WGET_FAIL=wikipedia_en_test_2026-01.zim.torrent
  run_updater -d -t "$ZIMS"
  assert_failure 1
  assert_output --partial 'Torrent download failed'
}

@test "p2-cli: a failed download in dry-run is never attempted and exits 0" {
  make_local_zim "$OLD_WP"
  export FAKE_WGET_FAIL=wikipedia_en_test_2026-01
  run_updater "$ZIMS"
  assert_success
}

@test "p2-cli: a catalog with more than one download host exits 1" {
  use_fixture_copy
  sed -i '0,/https:\/\/download\.kiwix\.test\/zim\//s##https://other.kiwix.test/zim/#' "$FAKE_FIXTURES/catalog.xml"
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'Too many zim base urls found'
}
