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

@test "p2-cli: -f together with -t aborts with exit 2 (-f implies -c)" {
  make_local_zim "$OLD_WP"
  run_updater --separate-stderr -f -t "$ZIMS"
  assert_failure 2
  [[ "$stderr" == *'Calculating Checksum not available with torrenting'* ]]
  run cat "$FAKE_WGET_LOG"
  assert_output ''
}

###############################################################################
# argument validation (H5)

@test "p2-cli: -n with a valid size (1G) is accepted" {
  make_local_zim "$OLD_WP"
  run_updater -n 1G "$ZIMS"
  assert_success
  assert_output --partial 'Update skipped (minimum'
}

@test "p2-cli: -x with a valid binary size (2Ki) is accepted" {
  make_local_zim big_test_2026-01.zim
  run_updater -x 2Ki "$ZIMS"
  assert_success
  # numfmt prints the locale's decimal separator.
  assert_output --regexp 'Update skipped \(maximum: 2[.,]0Ki'
}

@test "p2-cli: -x without a value exits 2 with usage on stderr" {
  make_local_zim "$OLD_WP"
  run_updater --separate-stderr "$ZIMS" -x
  assert_failure 2
  [[ "$stderr" == *'-x requires a size'* ]]
  [[ "$stderr" == *'Usage:'* ]]
  run cat "$FAKE_WGET_LOG"
  assert_output ''
}

@test "p2-cli: -n followed by another option exits 2" {
  make_local_zim "$OLD_WP"
  run_updater -n -d "$ZIMS"
  assert_failure 2
  assert_output --partial "Invalid minimum size: '-d'"
}

@test "p2-cli: a fractional byte size exits 2" {
  make_local_zim "$OLD_WP"
  run_updater -n 1.5 "$ZIMS"
  assert_failure 2
}

@test "p2-cli: an unknown short option exits 2 with usage" {
  make_local_zim "$OLD_WP"
  run_updater -z "$ZIMS"
  assert_failure 2
  assert_output --partial 'Unknown option: -z'
  assert_output --partial 'Usage:'
}

@test "p2-cli: -l without a value exits 2" {
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS" -l
  assert_failure 2
  assert_output --partial '-l requires a country code'
}

@test "p2-cli: -l followed by another option exits 2 instead of eating it" {
  make_local_zim "$OLD_WP"
  run_updater -l -d "$ZIMS"
  assert_failure 2
  assert_output --partial '-l requires a country code'
}

@test "p2-cli: an invalid -l code still falls back and runs" {
  make_local_zim "$OLD_WP"
  run_updater --separate-stderr -l se "$ZIMS"
  assert_success
  [[ "$stderr" == *"Invalid country code 'se'"* ]]
  run grep -c 'meta4?country=$' "$FAKE_WGET_LOG"
  assert_output '1'
}

###############################################################################
# N: new defects found while working on Phase 2 (skipped until fixed)

@test "N6a: -f -d exits 1 when it finds a corrupt ZIM it has to keep" {
  make_local_zim orphan_test_2025-01.zim 'orphan payload'
  make_local_sha256 orphan_test_2025-01.zim
  printf 'tampered' >"$ZIMS/orphan_test_2025-01.zim"
  run_updater -f -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed, but no online version to replace it with'
}

@test "N6a: -f exits 1 when a ZIM cannot be verified (metadata unavailable)" {
  make_local_zim wikipedia_en_test_2026-01.zim --from-remote zim/wikipedia/wikipedia_en_test_2026-01.zim
  export FAKE_WGET_META_FAIL=1
  run_updater -f "$ZIMS"
  assert_failure 1
  assert_output --partial 'cannot verify'
}

@test "N6a: -f on a healthy library exits 0" {
  make_local_zim wikipedia_en_test_2026-01.zim --from-remote zim/wikipedia/wikipedia_en_test_2026-01.zim
  run_updater -f -d "$ZIMS"
  assert_success
  assert_output --partial 'Checksum passed'
}

@test "N7a: a failed download keeps its partial file and lock so the next run resumes it" {
  skip "N7a: step 5 cleanup deletes the partial download and its lock in the same run"
  make_local_zim "$OLD_WP"
  export FAKE_WGET_FAIL=wikipedia_en_test_2026-01
  run_updater -d "$ZIMS"
  assert_failure 1
  [[ -f "$ZIMS/.~lock.$NEW_WP" ]]
  [[ -s "$ZIMS/$NEW_WP" ]]
  [[ -f "$ZIMS/$OLD_WP" ]]
}
