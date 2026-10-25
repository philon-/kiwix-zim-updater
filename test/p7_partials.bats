#!/usr/bin/env bats
# Downloads are staged in <name>.zim.part and renamed only once verified; --clean-partials.

setup() {
  load 'helpers/common'
  common_setup
}

W=wikipedia_en_test_2026-01.zim
WOLD=wikipedia_en_test_2025-01.zim
WREMOTE=zim/wikipedia/wikipedia_en_test_2026-01.zim

@test "part: a successful update leaves no .part file and purges the old ZIM" {
  make_local_zim "$WOLD"
  run_updater -d -c "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  refute_exists "$ZIMS/$W.part"
  refute_exists "$ZIMS/$WOLD"
}

@test "part: a failed download never produces a file under the new ZIM's name" {
  make_local_zim "$WOLD"
  export FAKE_WGET_FAIL="$W"
  run_updater -d "$ZIMS"
  assert_failure 1
  refute_exists "$ZIMS/$W"
  assert_nonempty "$ZIMS/$W.part"
  assert_exists "$ZIMS/$WOLD"
}

@test "part: a short download (wget exit 0) stays a .part file" {
  make_local_zim "$WOLD"
  export FAKE_WGET_SHORT="$W"
  run_updater -d "$ZIMS"
  assert_failure 1
  refute_exists "$ZIMS/$W"
  assert_nonempty "$ZIMS/$W.part"
}

@test "part: a download that fails -c is removed, nothing is left under the new name" {
  make_local_zim "$WOLD"
  export FAKE_WGET_CORRUPT="$W"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  refute_exists "$ZIMS/$W"
  refute_exists "$ZIMS/$W.part"
  assert_exists "$ZIMS/$WOLD"
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
  refute_exists "$ZIMS/$W.part"
  refute_exists "$ZIMS/$WOLD"
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
  refute_exists "$ZIMS/$W.part"
}

@test "part: a .part larger than published is started over" {
  make_local_zim "$WOLD"
  { cat "$(remote_file "$WREMOTE")"; printf 'extra'; } >"$ZIMS/$W.part"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial 'is larger than published, starting the download over'
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  refute_exists "$ZIMS/$W.part"
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
  assert_zim_unchanged "$W"
  assert_nonempty "$ZIMS/$W.part"
}

@test "part: -f -d replaces a corrupt current ZIM once the replacement is verified" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  printf 'X' | dd of="$ZIMS/$W" bs=1 seek=10 conv=notrunc status=none
  run_updater -f -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  refute_exists "$ZIMS/$W.part"
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
  refute_exists "$ZIMS/.~lock.$W"
  refute_exists "$ZIMS/$W.part"
  refute_exists "$ZIMS/$WOLD"
}

@test "part: a lone old-style locked partial stays in place until its replacement is verified" {
  head -c 1000 "$(remote_file "$WREMOTE")" >"$ZIMS/$W"
  touch "$ZIMS/.~lock.$W"
  export FAKE_WGET_NETFAIL="$W"
  run_updater -d "$ZIMS"
  assert_failure 1
  # Still under its own name with its lock (it keeps the ZIM in the listing); nothing was written into it
  assert_nonempty "$ZIMS/$W"
  assert_exists "$ZIMS/.~lock.$W"
  refute_exists "$ZIMS/$W.part"
  unset FAKE_WGET_NETFAIL
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  refute_exists "$ZIMS/.~lock.$W"
}

###############################################################################
# --clean-partials

@test "clean-partials: without the flag, a .part of a release no longer in the catalog is only listed" {
  make_local_zim "$WOLD"
  printf 'partial' >"$ZIMS/wikipedia_en_test_2025-06.zim.part"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial "can no longer be used: $ZIMS/wikipedia_en_test_2025-06.zim.part (--clean-partials removes it)"
  assert_exists "$ZIMS/wikipedia_en_test_2025-06.zim.part"
}

@test "clean-partials: removes a .part of a release no longer in the catalog" {
  make_local_zim "$WOLD"
  printf 'partial' >"$ZIMS/wikipedia_en_test_2025-06.zim.part"
  run_updater -d --clean-partials "$ZIMS"
  assert_success
  assert_output --partial "Removing unfinished download that can no longer be used: $ZIMS/wikipedia_en_test_2025-06.zim.part"
  refute_exists "$ZIMS/wikipedia_en_test_2025-06.zim.part"
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
}

@test "clean-partials: removes a .part whose finished ZIM -f just verified as good" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  printf 'partial' >"$ZIMS/$W.part"
  run_updater -f -d --clean-partials "$ZIMS"
  assert_success
  assert_output --partial 'Checksum passed'
  refute_exists "$ZIMS/$W.part"
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
}

@test "clean-partials: works on a run with nothing to download" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  printf 'partial' >"$ZIMS/wikipedia_en_test_2025-06.zim.part"
  run_updater -d --clean-partials "$ZIMS"
  assert_success
  assert_output --partial 'Nothing to download'
  refute_exists "$ZIMS/wikipedia_en_test_2025-06.zim.part"
}

@test "clean-partials: keeps the resumable replacement of a corrupt ZIM between runs" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  printf 'X' | dd of="$ZIMS/$W" bs=1 seek=10 conv=notrunc status=none
  # A -f run starts the replacement and is interrupted
  FAKE_WGET_FAIL="$W" run_updater -f -d "$ZIMS"
  assert_failure 1
  assert_nonempty "$ZIMS/$W.part"
  keep_copy "$W.part"
  # The nightly run with --clean-partials must leave it for the next -f run
  run_updater -d --clean-partials "$ZIMS"
  assert_success
  assert_output --partial "Keeping unfinished download for a later run to resume: $ZIMS/$W.part"
  assert_zim_unchanged "$W.part"
  run_updater -f -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  refute_exists "$ZIMS/$W.part"
}

@test "clean-partials: keeps a .part that a later run can still resume (outside -x)" {
  make_local_zim big_test_2025-01.zim
  head -c 1000 "$(remote_file zim/other/big_test_2026-03.zim)" >"$ZIMS/big_test_2026-03.zim.part"
  run_updater -d -x 2Ki --clean-partials "$ZIMS"
  assert_success
  assert_output --partial "Keeping unfinished download for a later run to resume: $ZIMS/big_test_2026-03.zim.part"
  assert_nonempty "$ZIMS/big_test_2026-03.zim.part"
}

@test "clean-partials: never touches files behind an old-style lock" {
  make_local_zim "$WOLD"
  keep_copy "$WOLD"
  touch "$ZIMS/.~lock.$WOLD"
  run_updater -d -p --clean-partials "$ZIMS"
  assert_success
  assert_output --partial 'Keeping an interrupted download left by an older version of this script'
  assert_zim_unchanged "$WOLD"
  assert_exists "$ZIMS/.~lock.$WOLD"
}

@test "clean-partials: in dry-run it only lists what it would remove" {
  make_local_zim "$WOLD"
  printf 'partial' >"$ZIMS/wikipedia_en_test_2025-06.zim.part"
  run_updater --clean-partials "$ZIMS"
  assert_success
  assert_output --partial '*** Simulated *** Removing unfinished download that can no longer be used'
  assert_exists "$ZIMS/wikipedia_en_test_2025-06.zim.part"
}

@test "docs: the README usage block matches the -h output" {
  run bash "$SCRIPT_COPY" -h
  assert_success
  local readme
  readme="$(awk '/^## Usage$/{u=1;next} u && /^```text$/{p=1;next} p && /^```$/{exit} p' "$REPO_ROOT/README.md")"
  assert_equal "$output" "$readme"
}

@test "part: a lone old-style locked file larger than published is replaced, never appended to" {
  { cat "$(remote_file "$WREMOTE")"; printf 'garbage'; } >"$ZIMS/$W"
  touch "$ZIMS/.~lock.$W"
  run_updater -d "$ZIMS"
  assert_success
  run wget_downloads
  assert_output --partial "-O $ZIMS/$W.part"
  refute_output --partial "-O $ZIMS/$W "
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
  refute_exists "$ZIMS/.~lock.$W"
  refute_exists "$ZIMS/$W.part"
}

@test "part: a lone old-style locked file is never written to, even when the replacement fails" {
  { cat "$(remote_file "$WREMOTE")"; printf 'garbage'; } >"$ZIMS/$W"
  keep_copy "$W"
  touch "$ZIMS/.~lock.$W"
  export FAKE_WGET_FAIL="$W"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_zim_unchanged "$W"
  assert_exists "$ZIMS/.~lock.$W"
}

@test "part: a complete lone old-style locked file that fails -c is kept and becomes a normal ZIM" {
  LC_ALL=C tr '\000-\377' '\001-\377\000' <"$(remote_file "$WREMOTE")" >"$ZIMS/$W"
  keep_copy "$W"
  touch "$ZIMS/.~lock.$W"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  assert_output --partial 'run with -f to replace it'
  assert_zim_unchanged "$W"
  refute_exists "$ZIMS/.~lock.$W"
  # ...and -f then replaces it with a verified download
  run_updater -f -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
}

@test "part: a locked catalog version next to an older version of the same title is migrated, whatever the sort order" {
  make_local_zim wiktionary_fr_test_2026-02.zim
  head -c 1000 "$(remote_file zim/wiktionary/wiktionary_fr_test_2026-02a.zim)" >"$ZIMS/wiktionary_fr_test_2026-02a.zim"
  touch "$ZIMS/.~lock.wiktionary_fr_test_2026-02a.zim"
  LC_ALL=en_US.UTF-8 run_updater -d "$ZIMS"
  assert_success
  run wget_downloads
  refute_output --partial "-O $ZIMS/wiktionary_fr_test_2026-02a.zim "
  cmp "$ZIMS/wiktionary_fr_test_2026-02a.zim" "$(remote_file zim/wiktionary/wiktionary_fr_test_2026-02a.zim)"
  refute_exists "$ZIMS/wiktionary_fr_test_2026-02.zim"
}
