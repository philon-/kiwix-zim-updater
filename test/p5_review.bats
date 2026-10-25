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

@test "R2: an intact only copy with a stale lock survives and is never re-downloaded" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  make_local_sha256 "$W"
  touch "$ZIMS/.~lock.$W"
  # Since N11 a complete locked file is verified instead of resumed, so a network failure cannot touch it
  FAKE_WGET_NETFAIL="$W" run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ -f "$ZIMS/$W.sha256" ]]
  [[ ! -e "$ZIMS/.~lock.$W" ]]
  run wget_downloads
  assert_output ''
}

@test "R2: a complete new download with a stale lock completes the update without downloading again" {
  make_local_zim "$WOLD"
  cp "$(remote_file "$WREMOTE")" "$ZIMS/$W"
  touch "$ZIMS/.~lock.$W"
  FAKE_WGET_NETFAIL="$W" run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/$WOLD" ]]
  [[ ! -e "$ZIMS/.~lock.$W" ]]
}

@test "R2: a shorter interrupted download whose resume fails is kept for the next run" {
  make_local_zim "$WOLD"
  keep_copy "$WOLD"
  head -c 1000 "$(remote_file "$WREMOTE")" >"$ZIMS/$W"
  touch "$ZIMS/.~lock.$W"
  FAKE_WGET_NETFAIL="$W" run_updater -d "$ZIMS"
  assert_failure 1
  [[ -s "$ZIMS/$W" ]]
  [[ -f "$ZIMS/.~lock.$W" ]]
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

@test "R3: -f -d verifies a locked outdated ZIM against its own checksum and never deletes it" {
  make_local_zim "$WOLD"
  make_local_sha256 "$WOLD"
  keep_copy "$WOLD"
  cp "$ZIMS/$WOLD.sha256" "$SANDBOX/sha256.orig"
  touch "$ZIMS/.~lock.$WOLD"
  export FAKE_WGET_FAIL="$W"
  run_updater -f -d "$ZIMS"
  assert_success
  assert_output --partial 'Cached Checksum Found'
  assert_output --partial 'Checksum passed'
  cmp "$ZIMS/$WOLD" "$SANDBOX/$WOLD.orig"
  cmp "$ZIMS/$WOLD.sha256" "$SANDBOX/sha256.orig"
  run wget_downloads
  assert_output ''
}

@test "R3: -f -d -p never rewrites a locked outdated ZIM's cached checksum with the newer release's hash" {
  make_local_zim "$WOLD"
  make_local_sha256 "$WOLD"
  cp "$ZIMS/$WOLD.sha256" "$SANDBOX/sha256.orig"
  touch "$ZIMS/.~lock.$WOLD"
  run_updater -f -d -p "$ZIMS"
  cmp "$ZIMS/$WOLD.sha256" "$SANDBOX/sha256.orig"
  [[ -f "$ZIMS/$WOLD" ]]
}

@test "R5: -f -d does not resume an update download for an outdated ZIM it checks by cached checksum" {
  make_local_zim "$WOLD"
  make_local_sha256 "$WOLD"
  head -c 1000 "$(remote_file "$WREMOTE")" >"$ZIMS/$W"
  cp "$ZIMS/$W" "$SANDBOX/partial.orig"
  touch "$ZIMS/.~lock.$W"
  run_updater -f -d "$ZIMS"
  assert_success
  refute_output --partial 'resuming'
  refute_output --partial 'removing corrupt file'
  cmp "$ZIMS/$W" "$SANDBOX/partial.orig"
  [[ -f "$ZIMS/.~lock.$W" ]]
  run wget_downloads
  assert_output ''
}

@test "R5: -f -d still finishes an interrupted download of the current catalog version" {
  head -c 1000 "$(remote_file "$WREMOTE")" >"$ZIMS/$W"
  touch "$ZIMS/.~lock.$W"
  run_updater -f -d "$ZIMS"
  assert_success
  assert_output --partial 'Incomplete download detected, resuming'
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/.~lock.$W" ]]
}

@test "R7: dry-run -f exits 1 for a truncated current ZIM, like for a corrupt outdated one" {
  make_local_zim "$W" "truncated"
  run_updater -f "$ZIMS"
  assert_failure 1
  assert_output --partial 'File size verification failed'
}

@test "R7: dry-run -f -p says the purge would be skipped, not that it removes the file" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  printf 'X' | dd of="$ZIMS/$W" bs=1 seek=10 conv=notrunc status=none
  run_updater -f -p "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed but purge was skipped'
  refute_output --partial 'removing corrupt file'
}

@test "R9: -f verifies a current ZIM offline against its cached checksum" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  make_local_sha256 "$W"
  # Run once online so the catalog index is cached, then go "offline"
  run_updater -f "$ZIMS"
  assert_success
  export FAKE_WGET_META_FAIL=1 FAKE_WGET_CATALOG_FAIL=1
  run_updater -f "$ZIMS"
  assert_success
  assert_output --partial 'verifying against the cached checksum'
  assert_output --partial 'Checksum passed'
}

@test "R9: offline -f still detects a corrupt current ZIM through its cached checksum" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  make_local_sha256 "$W"
  printf 'X' | dd of="$ZIMS/$W" bs=1 seek=10 conv=notrunc status=none
  export FAKE_WGET_META_FAIL=1
  run_updater -f "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed'
}

@test "wget2: downloads also carry --no-metalink, so -O is always honoured" {
  export FAKE_WGET_FLAVOR=wget2
  make_local_zim "$WOLD"
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  run wget_downloads
  assert_output --partial -- '--no-metalink'
  run bash -c 'grep -e " -O " "$1" | grep -v -e " -O - " | grep -v -e --no-metalink' _ "$FAKE_WGET_LOG"
  assert_output ''
}

@test "N11: a complete locked download is verified, not re-requested (Wget2 would append it again)" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  make_local_sha256 "$W"
  touch "$ZIMS/.~lock.$W"
  export FAKE_WGET_FLAVOR=wget2
  run_updater -d -c "$ZIMS"
  assert_success
  assert_output --partial 'Interrupted download is already complete, verifying it'
  assert_output --partial 'Checksum passed'
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/.~lock.$W" ]]
  run wget_downloads
  assert_output ''
}

@test "N11: a complete locked download that fails -c is deleted and the old ZIM is kept" {
  make_local_zim "$WOLD"
  keep_copy "$WOLD"
  LC_ALL=C tr '\000-\377' '\001-\377\000' <"$(remote_file "$WREMOTE")" >"$ZIMS/$W"
  touch "$ZIMS/.~lock.$W"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed'
  cmp "$ZIMS/$WOLD" "$SANDBOX/$WOLD.orig"
  [[ ! -e "$ZIMS/$W" ]]
}
