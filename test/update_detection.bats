#!/usr/bin/env bats
# Characterization: matching local ZIMs to the catalog and comparing dates.

setup() {
  load 'helpers/common'
  common_setup
}

@test "detect: an older local ZIM has an update" {
  make_local_zim wikipedia_en_test_2025-12.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'wikipedia_en_test_2025-12.zim  [wikipedia]'
  assert_output --partial 'Update found! --> 2026-01'
}

@test "detect: an older local ZIM from the same year has an update" {
  make_local_zim big_test_2026-01.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'Update found! --> 2026-03'
}

@test "detect: an equal local ZIM has no new update" {
  make_local_zim wikipedia_en_test_2026-01.zim --from-remote zim/wikipedia/wikipedia_en_test_2026-01.zim
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
  make_local_zim wiktionary_fr_test_2026-02.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'Update found! --> 2026-02a'
}

@test "detect: local 2026-02a equal to remote 2026-02a has no new update" {
  make_local_zim wiktionary_fr_test_2026-02a.zim --from-remote zim/wiktionary/wiktionary_fr_test_2026-02a.zim
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
  make_local_zim wikipedia_en_test_2025-12.zim
  printf 'x' >"$ZIMS/notes.txt"
  printf 'x' >"$ZIMS/wikipedia_en_test_2025-12.zim.sha256"
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
  make_local_zim wikipedia_en_test_2025-12.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '1 ZIM(s) found.'
  assert_output --partial '- wikipedia_en_test_2025-12.zim:'
  refute_output --partial '- wikipedia_en_test_2025-06.zim:'
  run download_log
  assert_line 'Disregarding wikipedia_en_test_2025-06.zim because it is shadowed by wikipedia_en_test_2025-12.zim'
}

@test "detect: local 2026-02 and 2026-02a - 02 is shadowed by 02a" {
  make_local_zim wiktionary_fr_test_2026-02.zim
  make_local_zim wiktionary_fr_test_2026-02a.zim --from-remote zim/wiktionary/wiktionary_fr_test_2026-02a.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '1 ZIM(s) found.'
  assert_output --partial 'No new update'
  run download_log
  assert_line 'Disregarding wiktionary_fr_test_2026-02.zim because it is shadowed by wiktionary_fr_test_2026-02a.zim'
}

@test "detect: an interrupted newer download is disregarded in favour of the old ZIM" {
  make_local_zim wikipedia_en_test_2025-12.zim
  make_local_zim wikipedia_en_test_2026-01.zim 'partial'
  : >"$ZIMS/.~lock.wikipedia_en_test_2026-01.zim"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '- wikipedia_en_test_2025-12.zim:'
  run download_log
  assert_line 'Disregarding wikipedia_en_test_2026-01.zim because it was interrupted by wikipedia_en_test_2025-12.zim'
}
