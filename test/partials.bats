#!/usr/bin/env bats
# Unfinished downloads: a download is staged in <name>.zim.part and renamed only once verified, and the next run
# resumes it. Also the .~lock. partials left by older versions, the -n/-x limits on resuming, and --clean-partials.

setup() {
  load 'helpers/common'
  common_setup
}

###############################################################################
# .part files

@test "a failed download keeps its .part file for the next run and nothing under the new name (N7a)" {
  make_local_zim "$WP_OLD"
  export FAKE_WGET_FAIL="$WP_NEW"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_nonempty "$ZIMS/$WP_NEW.part"
  refute_exists "$ZIMS/$WP_NEW"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
  assert_exists "$ZIMS/$WP_OLD"
  assert_output --partial "Keeping interrupted download for the next run to resume: $ZIMS/$WP_NEW.part"
}

@test "the next run resumes the .part file and completes the update (N7a)" {
  make_local_zim "$WP_OLD"
  export FAKE_WGET_FAIL="$WP_NEW"
  run_updater -d "$ZIMS"
  assert_failure 1
  unset FAKE_WGET_FAIL
  : >"$FAKE_WGET_LOG"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial 'ZIM download was interrupted. Continuing...'
  run wget_downloads
  assert_output --partial "-c -O $ZIMS/$WP_NEW.part"
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_NEW.part"
  refute_exists "$ZIMS/$WP_OLD"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
}

@test "a download that is too large is not kept for resuming (N7a)" {
  use_fixture_copy
  make_local_zim "$WP_OLD"
  # Serve more bytes than the meta4 announces: wget -c can never fix that.
  printf 'extra' >>"$(remote_file "$WP_REMOTE")"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'it is larger than published and cannot be resumed'
  refute_exists "$ZIMS/$WP_NEW.part"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
  refute_exists "$ZIMS/$WP_NEW"
  assert_exists "$ZIMS/$WP_OLD"
}

@test "a complete .part (run killed while hashing) is verified and renamed without downloading" {
  make_local_zim "$WP_OLD"
  cp "$(remote_file "$WP_REMOTE")" "$ZIMS/$WP_NEW.part"
  export FAKE_WGET_FLAVOR=wget2
  run_updater -d -c "$ZIMS"
  assert_success
  assert_output --partial 'Interrupted download is already complete, verifying it'
  run wget_downloads
  assert_output ''
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_NEW.part"
}

@test "a .part larger than published is started over" {
  make_local_zim "$WP_OLD"
  { cat "$(remote_file "$WP_REMOTE")"; printf 'extra'; } >"$ZIMS/$WP_NEW.part"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial 'is larger than published, starting the download over'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_NEW.part"
}

@test "-f -d keeps a corrupt current ZIM until its replacement is verified" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  keep_copy "$WP_NEW"
  export FAKE_WGET_FAIL="$WP_NEW"
  run_updater -f -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed, downloading a replacement'
  assert_zim_unchanged "$WP_NEW"
  assert_nonempty "$ZIMS/$WP_NEW.part"
}

@test "-f -d replaces a corrupt current ZIM once the replacement is verified" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  run_updater -f -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_NEW.part"
  run cat "$ZIMS/$WP_NEW.sha256"
  assert_output "$(cut -d' ' -f1 "$(remote_file "$WP_REMOTE.sha256")") $WP_NEW"
}

###############################################################################
# Old-style partials: a .~lock.<name> file next to the partial ZIM, left by older versions of the script

@test "an old-style locked partial next to an older version is resumed as a .part file" {
  make_local_zim "$WP_OLD"
  head -c 1000 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial 'ZIM download was interrupted. Continuing...'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
  refute_exists "$ZIMS/$WP_NEW.part"
  refute_exists "$ZIMS/$WP_OLD"
}

@test "a locked catalog version next to an older version of the same title is migrated, whatever the sort order" {
  make_local_zim "$WT_OLD"
  head -c 1000 "$(remote_file "$WT_REMOTE")" >"$ZIMS/$WT_NEW"
  touch "$ZIMS/.~lock.$WT_NEW"
  LC_ALL=en_US.UTF-8 run_updater -d "$ZIMS"
  assert_success
  run wget_downloads
  refute_output --partial "-O $ZIMS/$WT_NEW "
  cmp "$ZIMS/$WT_NEW" "$(remote_file "$WT_REMOTE")"
  refute_exists "$ZIMS/$WT_OLD"
}

@test "a lone old-style locked partial stays in place until its replacement is verified" {
  head -c 1000 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  export FAKE_WGET_NETFAIL="$WP_NEW"
  run_updater -d "$ZIMS"
  assert_failure 1
  # Still under its own name with its lock (it keeps the ZIM in the listing); nothing was written into it
  assert_nonempty "$ZIMS/$WP_NEW"
  assert_exists "$ZIMS/.~lock.$WP_NEW"
  refute_exists "$ZIMS/$WP_NEW.part"
  unset FAKE_WGET_NETFAIL
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
}

@test "a lone old-style locked file larger than published is replaced, never appended to" {
  { cat "$(remote_file "$WP_REMOTE")"; printf 'garbage'; } >"$ZIMS/$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  run_updater -d "$ZIMS"
  assert_success
  run wget_downloads
  assert_output --partial "-O $ZIMS/$WP_NEW.part"
  refute_output --partial "-O $ZIMS/$WP_NEW "
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
  refute_exists "$ZIMS/$WP_NEW.part"
}

@test "a lone old-style locked file is never written to, even when the replacement fails" {
  { cat "$(remote_file "$WP_REMOTE")"; printf 'garbage'; } >"$ZIMS/$WP_NEW"
  keep_copy "$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  export FAKE_WGET_FAIL="$WP_NEW"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_zim_unchanged "$WP_NEW"
  assert_exists "$ZIMS/.~lock.$WP_NEW"
}

@test "a complete lone old-style locked file that fails -c is kept and becomes a normal ZIM" {
  LC_ALL=C tr '\000-\377' '\001-\377\000' <"$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  keep_copy "$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  assert_output --partial 'run with -f to replace it'
  assert_zim_unchanged "$WP_NEW"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
  # ...and -f then replaces it with a verified download
  run_updater -f -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
}

@test "an intact only copy with a stale lock survives and is never re-downloaded (R2)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_sha256 "$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  # Since N11 a complete locked file is verified instead of resumed, so a network failure cannot touch it
  FAKE_WGET_NETFAIL="$WP_NEW" run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  assert_exists "$ZIMS/$WP_NEW.sha256"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
  run wget_downloads
  assert_output ''
}

@test "a complete new download with a stale lock completes the update without downloading again (R2)" {
  make_local_zim "$WP_OLD"
  cp "$(remote_file "$WP_REMOTE")" "$ZIMS/$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  FAKE_WGET_NETFAIL="$WP_NEW" run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_OLD"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
}

@test "a shorter interrupted download whose resume fails is kept for the next run (R2)" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  head -c 1000 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  FAKE_WGET_NETFAIL="$WP_NEW" run_updater -d "$ZIMS"
  assert_failure 1
  # The old-style locked partial next to an older version becomes a .part file and is kept for resuming
  assert_nonempty "$ZIMS/$WP_NEW.part"
  refute_exists "$ZIMS/$WP_NEW"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
  assert_zim_unchanged "$WP_OLD"
}

@test "a complete locked download is verified, not re-requested (Wget2 would append it again) (N11)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_sha256 "$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  export FAKE_WGET_FLAVOR=wget2
  run_updater -d -c "$ZIMS"
  assert_success
  assert_output --partial 'Interrupted download is already complete, verifying it'
  assert_output --partial 'Checksum passed'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
  run wget_downloads
  assert_output ''
}

@test "a complete locked download that fails -c is deleted and the old ZIM is kept (N11)" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  LC_ALL=C tr '\000-\377' '\001-\377\000' <"$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  touch "$ZIMS/.~lock.$WP_NEW"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed'
  assert_zim_unchanged "$WP_OLD"
  refute_exists "$ZIMS/$WP_NEW"
}

@test "-d -p keeps an old ZIM that carries a stale lock (R1)" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  touch "$ZIMS/.~lock.$WP_OLD"
  run_updater -d -p "$ZIMS"
  assert_zim_unchanged "$WP_OLD"
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  assert_output --partial 'Keeping an interrupted download left by an older version of this script'
}

@test "without -p, a verified update still purges an old ZIM with a stale lock and removes the lock (R1)" {
  make_local_zim "$WP_OLD"
  touch "$ZIMS/.~lock.$WP_OLD"
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_OLD"
  refute_exists "$ZIMS/.~lock.$WP_OLD"
}

@test "a partial left by an earlier run is kept when this run does not touch it (R6)" {
  make_local_zim small_test_2025-01.zim
  make_local_zim big_test_2025-01.zim
  head -c 1000 "$(remote_file zim/other/big_test_2026-03.zim)" >"$ZIMS/big_test_2026-03.zim"
  touch "$ZIMS/.~lock.big_test_2026-03.zim"
  run_updater -d -x 2Ki "$ZIMS"
  assert_success
  assert_nonempty "$ZIMS/big_test_2026-03.zim"
  assert_exists "$ZIMS/.~lock.big_test_2026-03.zim"
  # ...and a later run without the size limit resumes and finishes it
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/big_test_2026-03.zim" "$(remote_file zim/other/big_test_2026-03.zim)"
  refute_exists "$ZIMS/.~lock.big_test_2026-03.zim"
  refute_exists "$ZIMS/big_test_2025-01.zim"
}

@test "a stale lock without its download is removed, with its orphaned checksum (R6)" {
  make_local_zim "$WP_OLD"
  touch "$ZIMS/.~lock.ghost_test_2026-01.zim"
  printf '%064d ghost_test_2026-01.zim\n' 0 >"$ZIMS/ghost_test_2026-01.zim.sha256"
  run_updater -d "$ZIMS"
  assert_success
  refute_exists "$ZIMS/.~lock.ghost_test_2026-01.zim"
  refute_exists "$ZIMS/ghost_test_2026-01.zim.sha256"
}

###############################################################################
# The -n/-x size limits on resuming

BIG=big_test_2026-03.zim
BIG_REMOTE=zim/other/big_test_2026-03.zim

@test "size limits: a locked partial bigger than -x is neither resumed nor deleted" {
  head -c 1000 "$(remote_file "$BIG_REMOTE")" >"$ZIMS/$BIG"
  keep_copy "$BIG"
  touch "$ZIMS/.~lock.$BIG"
  run_updater -d -x 2Ki "$ZIMS"
  assert_success
  assert_output --partial 'outside the -n/-x size limits. Left as it is.'
  assert_zim_unchanged "$BIG"
  assert_exists "$ZIMS/.~lock.$BIG"
  run wget_downloads
  assert_output ''
}

@test "size limits: a locked partial smaller than -n is left alone, a later run without -n resumes it" {
  head -c 1000 "$(remote_file "$BIG_REMOTE")" >"$ZIMS/$BIG"
  touch "$ZIMS/.~lock.$BIG"
  run_updater -d -n 1Mi "$ZIMS"
  assert_success
  run wget_downloads
  assert_output ''
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$BIG" "$(remote_file "$BIG_REMOTE")"
  refute_exists "$ZIMS/.~lock.$BIG"
}

###############################################################################
# --clean-partials

@test "clean-partials: without the flag, a .part of a release no longer in the catalog is only listed" {
  make_local_zim "$WP_OLD"
  printf 'partial' >"$ZIMS/wikipedia_en_test_2025-06.zim.part"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial "can no longer be used: $ZIMS/wikipedia_en_test_2025-06.zim.part (--clean-partials removes it)"
  assert_exists "$ZIMS/wikipedia_en_test_2025-06.zim.part"
}

@test "clean-partials: removes a .part of a release no longer in the catalog" {
  make_local_zim "$WP_OLD"
  printf 'partial' >"$ZIMS/wikipedia_en_test_2025-06.zim.part"
  run_updater -d --clean-partials "$ZIMS"
  assert_success
  assert_output --partial "Removing unfinished download that can no longer be used: $ZIMS/wikipedia_en_test_2025-06.zim.part"
  refute_exists "$ZIMS/wikipedia_en_test_2025-06.zim.part"
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
}

@test "clean-partials: removes a .part whose finished ZIM -f just verified as good" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  printf 'partial' >"$ZIMS/$WP_NEW.part"
  run_updater -f -d --clean-partials "$ZIMS"
  assert_success
  assert_output --partial 'Checksum passed'
  refute_exists "$ZIMS/$WP_NEW.part"
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
}

@test "clean-partials: works on a run with nothing to download" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  printf 'partial' >"$ZIMS/wikipedia_en_test_2025-06.zim.part"
  run_updater -d --clean-partials "$ZIMS"
  assert_success
  assert_output --partial 'Nothing to download'
  refute_exists "$ZIMS/wikipedia_en_test_2025-06.zim.part"
}

@test "clean-partials: keeps the resumable replacement of a corrupt ZIM between runs" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  # A -f run starts the replacement and is interrupted
  FAKE_WGET_FAIL="$WP_NEW" run_updater -f -d "$ZIMS"
  assert_failure 1
  assert_nonempty "$ZIMS/$WP_NEW.part"
  keep_copy "$WP_NEW.part"
  # The nightly run with --clean-partials must leave it for the next -f run
  run_updater -d --clean-partials "$ZIMS"
  assert_success
  assert_output --partial "Keeping unfinished download for a later run to resume: $ZIMS/$WP_NEW.part"
  assert_zim_unchanged "$WP_NEW.part"
  run_updater -f -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_NEW.part"
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
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  touch "$ZIMS/.~lock.$WP_OLD"
  run_updater -d -p --clean-partials "$ZIMS"
  assert_success
  assert_output --partial 'Keeping an interrupted download left by an older version of this script'
  assert_zim_unchanged "$WP_OLD"
  assert_exists "$ZIMS/.~lock.$WP_OLD"
}

@test "clean-partials: in dry-run it only lists what it would remove" {
  make_local_zim "$WP_OLD"
  printf 'partial' >"$ZIMS/wikipedia_en_test_2025-06.zim.part"
  run_updater --clean-partials "$ZIMS"
  assert_success
  assert_output --partial '*** Simulated *** Removing unfinished download that can no longer be used'
  assert_exists "$ZIMS/wikipedia_en_test_2025-06.zim.part"
}
