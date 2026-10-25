#!/usr/bin/env bats
# Regression tests for the findings of the independent review (Phase 5, R1-R10).

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
}

W=wikipedia_en_test_2026-01.zim
WOLD=wikipedia_en_test_2025-01.zim
WREMOTE=zim/wikipedia/wikipedia_en_test_2026-01.zim

keep_copy() {
  cp "$ZIMS/$1" "$SANDBOX/$1.orig"
}

@test "R4: -c keeps the old ZIM when the metadata has no sha256 to check the download against" {
  use_fixture_copy
  sed -i '/sha-256/d' "$(remote_file "$WREMOTE.meta4")"
  make_local_zim "$WOLD"
  keep_copy "$WOLD"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  assert_output --partial "No valid sha256 published for $W"
  refute_output --partial 'Old ZIM purged'
  cmp "$ZIMS/$WOLD" "$SANDBOX/$WOLD.orig"
}

@test "R4: dry-run -c without a published sha256 only reports it" {
  use_fixture_copy
  sed -i '/sha-256/d' "$(remote_file "$WREMOTE.meta4")"
  make_local_zim "$WOLD"
  run_updater -c "$ZIMS"
  assert_success
  assert_output --partial 'the checksum could not be verified'
}

@test "R2: an intact only copy with a stale lock survives a transient failure and is finished next run" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  make_local_sha256 "$W"
  touch "$ZIMS/.~lock.$W"
  FAKE_WGET_NETFAIL="$W" run_updater -d "$ZIMS"
  assert_failure 1
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ -f "$ZIMS/$W.sha256" ]]
  [[ -f "$ZIMS/.~lock.$W" ]]
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/.~lock.$W" ]]
}

@test "R2: a complete new download with a stale lock is kept after a transient failure (old kept too)" {
  make_local_zim "$WOLD"
  keep_copy "$WOLD"
  cp "$(remote_file "$WREMOTE")" "$ZIMS/$W"
  touch "$ZIMS/.~lock.$W"
  FAKE_WGET_NETFAIL="$W" run_updater -d "$ZIMS"
  assert_failure 1
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  cmp "$ZIMS/$WOLD" "$SANDBOX/$WOLD.orig"
}

@test "R1: -d -p keeps an old ZIM that carries a stale lock" {
  make_local_zim "$WOLD"
  keep_copy "$WOLD"
  touch "$ZIMS/.~lock.$WOLD"
  run_updater -d -p "$ZIMS"
  cmp "$ZIMS/$WOLD" "$SANDBOX/$WOLD.orig"
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  assert_output --partial 'Keeping an interrupted download left by an earlier run'
}

@test "R1: without -p, a verified update still purges an old ZIM with a stale lock and removes the lock" {
  make_local_zim "$WOLD"
  touch "$ZIMS/.~lock.$WOLD"
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/$WOLD" ]]
  [[ ! -e "$ZIMS/.~lock.$WOLD" ]]
}

@test "R6: a partial left by an earlier run is kept when this run does not touch it" {
  make_local_zim small_test_2025-01.zim
  make_local_zim big_test_2025-01.zim
  head -c 1000 "$(remote_file zim/other/big_test_2026-03.zim)" >"$ZIMS/big_test_2026-03.zim"
  touch "$ZIMS/.~lock.big_test_2026-03.zim"
  run_updater -d -x 2Ki "$ZIMS"
  assert_success
  [[ -s "$ZIMS/big_test_2026-03.zim" ]]
  [[ -f "$ZIMS/.~lock.big_test_2026-03.zim" ]]
  # ...and a later run without the size limit resumes and finishes it
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/big_test_2026-03.zim" "$(remote_file zim/other/big_test_2026-03.zim)"
  [[ ! -e "$ZIMS/.~lock.big_test_2026-03.zim" ]]
  [[ ! -e "$ZIMS/big_test_2025-01.zim" ]]
}

@test "R6: a stale lock without its download is removed, with its orphaned checksum" {
  make_local_zim "$WOLD"
  touch "$ZIMS/.~lock.ghost_test_2026-01.zim"
  printf '%064d ghost_test_2026-01.zim\n' 0 >"$ZIMS/ghost_test_2026-01.zim.sha256"
  run_updater -d "$ZIMS"
  assert_success
  [[ ! -e "$ZIMS/.~lock.ghost_test_2026-01.zim" ]]
  [[ ! -e "$ZIMS/ghost_test_2026-01.zim.sha256" ]]
}

@test "R10: -f -d -p finishing an interrupted current download prints no 'cannot remove'" {
  head -c 1000 "$(remote_file "$WREMOTE")" >"$ZIMS/$W"
  touch "$ZIMS/.~lock.$W"
  run_updater --separate-stderr -f -d -p "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/.~lock.$W" ]]
  [[ "$stderr" != *"cannot remove"* ]]
}
