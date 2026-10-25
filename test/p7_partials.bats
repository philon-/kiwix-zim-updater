#!/usr/bin/env bats
# Downloads are staged in <name>.zim.part and renamed only once verified; --clean-partials.

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

@test "part: a successful update leaves no .part file and purges the old ZIM" {
  make_local_zim "$WOLD"
  run_updater -d -c "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/$W.part" ]]
  [[ ! -e "$ZIMS/$WOLD" ]]
}

@test "part: a failed download never produces a file under the new ZIM's name" {
  make_local_zim "$WOLD"
  export FAKE_WGET_FAIL="$W"
  run_updater -d "$ZIMS"
  assert_failure 1
  [[ ! -e "$ZIMS/$W" ]]
  [[ -s "$ZIMS/$W.part" ]]
  [[ -f "$ZIMS/$WOLD" ]]
}

@test "part: a short download (wget exit 0) stays a .part file" {
  make_local_zim "$WOLD"
  export FAKE_WGET_SHORT="$W"
  run_updater -d "$ZIMS"
  assert_failure 1
  [[ ! -e "$ZIMS/$W" ]]
  [[ -s "$ZIMS/$W.part" ]]
}

@test "part: a download that fails -c is removed, nothing is left under the new name" {
  make_local_zim "$WOLD"
  export FAKE_WGET_CORRUPT="$W"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  [[ ! -e "$ZIMS/$W" ]]
  [[ ! -e "$ZIMS/$W.part" ]]
  [[ -f "$ZIMS/$WOLD" ]]
}

@test "part: the next run resumes the .part file and completes the update" {
  make_local_zim "$WOLD"
  head -c 1000 "$(remote_file "$WREMOTE")" >"$ZIMS/$W.part"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial 'ZIM download was interrupted. Continuing...'
  run wget_downloads
  assert_output --partial "-c -O $ZIMS/$W.part"
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/$W.part" ]]
  [[ ! -e "$ZIMS/$WOLD" ]]
}

@test "part: a complete .part (run killed while hashing) is verified and renamed without downloading" {
  make_local_zim "$WOLD"
  cp "$(remote_file "$WREMOTE")" "$ZIMS/$W.part"
  export FAKE_WGET_FLAVOR=wget2
  run_updater -d -c "$ZIMS"
  assert_success
  assert_output --partial 'Interrupted download is already complete, verifying it'
  run wget_downloads
  assert_output ''
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/$W.part" ]]
}

@test "part: a .part larger than published is started over" {
  make_local_zim "$WOLD"
  { cat "$(remote_file "$WREMOTE")"; printf 'extra'; } >"$ZIMS/$W.part"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial 'is larger than published, starting the download over'
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/$W.part" ]]
}

@test "part: a dry-run never creates a .part file" {
  make_local_zim "$WOLD"
  local before
  before="$(zim_dir_snapshot)"
  run_updater "$ZIMS"
  assert_success
  assert_equal "$(zim_dir_snapshot)" "$before"
}

@test "part: -f -d keeps a corrupt current ZIM until its replacement is verified" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  printf 'X' | dd of="$ZIMS/$W" bs=1 seek=10 conv=notrunc status=none
  keep_copy "$W"
  export FAKE_WGET_FAIL="$W"
  run_updater -f -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed, downloading a replacement'
  cmp "$ZIMS/$W" "$SANDBOX/$W.orig"
  [[ -s "$ZIMS/$W.part" ]]
}

@test "part: -f -d replaces a corrupt current ZIM once the replacement is verified" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  printf 'X' | dd of="$ZIMS/$W" bs=1 seek=10 conv=notrunc status=none
  run_updater -f -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/$W.part" ]]
  run cat "$ZIMS/$W.sha256"
  assert_output "$(cut -d' ' -f1 "$(remote_file "$WREMOTE.sha256")") $W"
}

@test "part: an old-style locked partial next to an older version becomes a .part file" {
  make_local_zim "$WOLD"
  head -c 1000 "$(remote_file "$WREMOTE")" >"$ZIMS/$W"
  touch "$ZIMS/.~lock.$W"
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/.~lock.$W" ]]
  [[ ! -e "$ZIMS/$W.part" ]]
  [[ ! -e "$ZIMS/$WOLD" ]]
}

@test "part: a lone old-style locked partial is still finished in place" {
  head -c 1000 "$(remote_file "$WREMOTE")" >"$ZIMS/$W"
  touch "$ZIMS/.~lock.$W"
  export FAKE_WGET_NETFAIL="$W"
  run_updater -d "$ZIMS"
  assert_failure 1
  # Still under its own name with its lock, so the next run finds and resumes it
  [[ -s "$ZIMS/$W" ]]
  [[ -f "$ZIMS/.~lock.$W" ]]
  [[ ! -e "$ZIMS/$W.part" ]]
  unset FAKE_WGET_NETFAIL
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  [[ ! -e "$ZIMS/.~lock.$W" ]]
}

@test "part: a .part of a release no longer in the catalog is listed, never deleted" {
  make_local_zim "$WOLD"
  printf 'partial' >"$ZIMS/wikipedia_en_test_2025-06.zim.part"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial "Unfinished download that can no longer be used: $ZIMS/wikipedia_en_test_2025-06.zim.part"
  [[ -f "$ZIMS/wikipedia_en_test_2025-06.zim.part" ]]
}

@test "docs: the README usage block matches the -h output" {
  run bash "$SCRIPT_COPY" -h
  assert_success
  local readme
  readme="$(awk '/^## Usage$/{u=1;next} u && /^```text$/{p=1;next} p && /^```$/{exit} p' "$REPO_ROOT/README.md")"
  assert_equal "$output" "$readme"
}
