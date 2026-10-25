#!/usr/bin/env bats
# Unit tests: source the sandboxed script (the source guard keeps main from running) and call its helpers directly.

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
  source "$SCRIPT_COPY"
  ZIMPath="$ZIMS/"
  LOG_FILE="$RUN_DIR/download.log"
  INDEX_FILE="$RUN_DIR/kiwix-index"
}

# assert_newer <date> <other date> / refute_newer <date> <other date>
assert_newer() {
  run zim_is_newer "$1" "$2"
  assert_success
}

refute_newer() {
  run zim_is_newer "$1" "$2"
  assert_failure
}

###############################################################################
# zim_date

@test "zim_date: prints the YYYY-MM date of a ZIM name" {
  run zim_date wikipedia_en_all_maxi_2026-01.zim
  assert_output '2026-01'
}

@test "zim_date: keeps the letter suffix of a re-release" {
  run zim_date wiktionary_fr_test_2026-02a.zim
  assert_output '2026-02a'
}

@test "zim_date: only the date right before .zim counts" {
  run zim_date test_2025-12_2026-01.zim
  assert_output '2026-01'
}

@test "zim_date: prints nothing for a name without a date" {
  run zim_date no_date_here.zim
  assert_output ''
  run zim_date wikipedia_en_test_2026-01.zim.torrent
  assert_output ''
  run zim_date ''
  assert_output ''
}

###############################################################################
# zim_is_newer

@test "zim_is_newer: a later month of the same year is newer" {
  assert_newer 2026-02 2026-01
  refute_newer 2026-01 2026-02
}

@test "zim_is_newer: a later year is newer, whatever the months" {
  assert_newer 2026-01 2025-12
  refute_newer 2025-12 2026-01
}

@test "zim_is_newer: a letter suffix is newer than the plain month and older than the next month" {
  assert_newer 2026-02a 2026-02
  refute_newer 2026-02 2026-02a
  assert_newer 2026-03 2026-02a
  refute_newer 2026-02a 2026-03
  assert_newer 2026-02 2026-01b
  refute_newer 2026-01b 2026-02
}

@test "zim_is_newer: letter suffixes are ordered alphabetically" {
  assert_newer 2026-02b 2026-02a
  refute_newer 2026-02a 2026-02b
}

@test "zim_is_newer: equal dates are not newer" {
  refute_newer 2026-01 2026-01
  refute_newer 2026-02a 2026-02a
}

@test "zim_is_newer: an empty date is older than any date" {
  assert_newer 2026-01 ''
  refute_newer '' 2026-01
  refute_newer '' ''
}
