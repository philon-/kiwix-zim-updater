#!/usr/bin/env bats
# Characterization: matching local ZIMs to the catalog and comparing dates.

setup() {
  load 'helpers/common'
  common_setup
}

@test "detect: an older local ZIM has an update" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial "$WP_OLD  [wikipedia]"
  assert_output --partial 'Update found! --> 2026-01'
}

@test "detect: an older local ZIM from the same year has an update" {
  make_local_zim big_test_2026-01.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'Update found! --> 2026-03'
}

@test "detect: an equal local ZIM has no new update" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'No new update'
  refute_output --partial 'Update found'
  assert_output --partial 'Nothing to download.'
}

@test "detect: a newer local ZIM has no new update" {
  make_local_zim wikipedia_en_test_2026-05.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'No new update'
  refute_output --partial 'Update found'
}

@test "detect: local 2026-02 vs remote 2026-02a (letter suffix) is an update" {
  make_local_zim "$WT_OLD"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'Update found! --> 2026-02a'
}

@test "detect: local 2026-02a equal to remote 2026-02a has no new update" {
  make_local_zim "$WT_NEW" --from-remote "$WT_REMOTE"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'No new update'
}

@test "detect: a local ZIM without a catalog entry has no online match" {
  make_local_zim orphan_test_2025-01.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'orphan_test_2025-01.zim  No online match found.'
  assert_output --partial 'Nothing to download.'
}

@test "detect: non-.zim files in the ZIM directory are ignored" {
  make_local_zim "$WP_OLD"
  printf 'x' >"$ZIMS/notes.txt"
  printf 'x' >"$ZIMS/$WP_OLD.sha256"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '1 ZIM(s) found.'
}

@test "detect: an empty ZIM directory reports no ZIMs" {
  run_updater "$ZIMS"
  assert_output --partial 'No ZIMs found. Exiting...'
}

@test "detect: two local versions of one ZIM - the older is disregarded" {
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

@test "detect: local 2026-02 and 2026-02a - 02 is shadowed by 02a" {
  make_local_zim "$WT_OLD"
  make_local_zim "$WT_NEW" --from-remote "$WT_REMOTE"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '1 ZIM(s) found.'
  assert_output --partial 'No new update'
  run download_log
  assert_line "Disregarding $WT_OLD because it is shadowed by $WT_NEW"
}

@test "detect: an interrupted newer download is disregarded in favour of the old ZIM" {
  make_local_zim "$WP_OLD"
  make_local_zim "$WP_NEW" 'partial'
  : >"$ZIMS/.~lock.$WP_NEW"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial "- $WP_OLD:"
  run download_log
  assert_line "Disregarding $WP_NEW because it was interrupted by $WP_OLD"
}
