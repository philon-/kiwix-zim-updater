#!/usr/bin/env bats
# Listing the local ZIMs, matching them to the catalog and comparing release dates.

setup() {
  load 'helpers/common'
  common_setup
}

###############################################################################
# Release dates

@test "an older local ZIM has an update" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial "$WP_OLD  [wikipedia]"
  assert_output --partial 'Update found! --> 2026-01'
}

@test "an older local ZIM from the same year has an update" {
  make_local_zim big_test_2026-01.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'Update found! --> 2026-03'
}

@test "an equal local ZIM has no new update" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'No new update'
  refute_output --partial 'Update found'
  assert_output --partial 'Nothing to download.'
}

@test "a newer local ZIM has no new update" {
  make_local_zim wikipedia_en_test_2026-05.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'No new update'
  refute_output --partial 'Update found'
}

@test "local 2026-02 vs remote 2026-02a (letter suffix) is an update" {
  make_local_zim "$WT_OLD"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'Update found! --> 2026-02a'
}

@test "local 2026-02a equal to remote 2026-02a has no new update" {
  make_local_zim "$WT_NEW" --from-remote "$WT_REMOTE"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'No new update'
}

@test "two local versions of one ZIM - the older is disregarded" {
  make_local_zim wikipedia_en_test_2025-06.zim
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '1 ZIM(s) found.'
  assert_output --partial "- $WP_OLD:"
  refute_output --partial '- wikipedia_en_test_2025-06.zim:'
  run download_log
  assert_line "Disregarding wikipedia_en_test_2025-06.zim because it is shadowed by $WP_OLD"
}

@test "local 2026-02 and 2026-02a - 02 is shadowed by 02a" {
  make_local_zim "$WT_OLD"
  make_local_zim "$WT_NEW" --from-remote "$WT_REMOTE"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '1 ZIM(s) found.'
  assert_output --partial 'No new update'
  run download_log
  assert_line "Disregarding $WT_OLD because it is shadowed by $WT_NEW"
}

@test "an interrupted newer download is disregarded in favour of the old ZIM" {
  make_local_zim "$WP_OLD"
  make_local_zim "$WP_NEW" 'partial'
  : >"$ZIMS/.~lock.$WP_NEW"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial "- $WP_OLD:"
  run download_log
  assert_line "Disregarding $WP_NEW because it was interrupted by $WP_OLD"
}

###############################################################################
# The ZIM listing (M1: listed with a glob, not by parsing ls)

@test "an empty ZIM directory reports no ZIMs and exits 1 (H1)" {
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'No ZIMs found. Exiting...'
}

@test "a local ZIM without a catalog entry has no online match" {
  make_local_zim orphan_test_2025-01.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'orphan_test_2025-01.zim  No online match found.'
  assert_output --partial 'Nothing to download.'
}

@test "non-.zim files in the ZIM directory are ignored" {
  make_local_zim "$WP_OLD"
  printf 'x' >"$ZIMS/notes.txt"
  printf 'x' >"$ZIMS/$WP_OLD.sha256"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '1 ZIM(s) found.'
}

@test "a ZIM name with spaces is listed as one ZIM (M1)" {
  make_local_zim "$WP_OLD"
  make_local_zim 'my notes_test_2025-01.zim'
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '✗ my notes_test_2025-01.zim  No online match found.'
  assert_output --partial "✓ $WP_OLD  [wikipedia]"
  assert_output --partial '2 ZIM(s) found.'
}

@test "an upper-case .ZIM extension is found, matched and not downloaded again (M1, N9)" {
  make_local_zim wikipedia_en_test_2026-01.ZIM --from-remote "$WP_REMOTE"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial '✓ wikipedia_en_test_2026-01.ZIM  [wikipedia]'
  assert_output --partial '1 ZIM(s) found.'
  assert_output --partial 'No new update'
  run wget_downloads
  assert_output ''
  assert_exists "$ZIMS/wikipedia_en_test_2026-01.ZIM"
}

@test "a directory named like a ZIM is ignored (M1)" {
  make_local_zim "$WP_OLD"
  mkdir "$ZIMS/x.zim" "$ZIMS/$WT_OLD"
  run_updater "$ZIMS"
  assert_success
  refute_output --partial 'x.zim'
  refute_output --partial 'wiktionary_fr_test_2026-02.zim'
  assert_output --partial '1 ZIM(s) found.'
}

@test "QUOTING_STYLE in the environment does not hide the ZIMs (M1)" {
  make_local_zim "$WP_OLD"
  export QUOTING_STYLE=shell-always
  run_updater "$ZIMS"
  assert_success
  assert_output --partial "- $WP_OLD:"
  assert_output --partial 'Update found!'
}

@test "a ZIM name containing a newline is left alone (M1)" {
  make_local_zim $'notes\nwikipedia_en_test_2025-12.zim' 'my notes'
  make_local_zim small_test_2025-12.zim --from-remote zim/other/small_test_2025-12.zim
  run_updater -d "$ZIMS"
  assert_success
  run cat "$ZIMS/"$'notes\nwikipedia_en_test_2025-12.zim'
  assert_output 'my notes'
  run wget_downloads
  assert_output ''
}

@test "a local ZIM whose name only ends in a catalog basename is not treated as that ZIM (N6c)" {
  make_local_zim 'my notes+wikipedia_en_test_2025-12.zim' 'my notes'
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial '✗ my notes+wikipedia_en_test_2025-12.zim  No online match found.'
  run cat "$ZIMS/my notes+wikipedia_en_test_2025-12.zim"
  assert_output 'my notes'
  run wget_downloads
  assert_output ''
}
