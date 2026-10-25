#!/usr/bin/env bats
# Known-bug tests. Each one asserts the CORRECT behaviour for a finding of
# the review (F*, H*, M*) or for a defect found while writing the harness
# (N*), and is skipped until the fix lands. The fix commit removes the skip.
#
# Count the open findings with: grep -c 'skip "[FHMN][0-9]' test/*.bats

setup() {
  load 'helpers/common'
  common_setup
}

###############################################################################
# F: data safety

@test "F1: a failed download (wget exit 4) keeps the old ZIM" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  export FAKE_WGET_FAIL="$WP_NEW"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_zim_unchanged "$WP_OLD"
  run download_log
  assert_line ' !!! DOWNLOAD FAILED !!!'
}

@test "F1: a short download with wget exit 0 keeps the old ZIM (size check without -c)" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  export FAKE_WGET_SHORT="$WP_NEW"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_zim_unchanged "$WP_OLD"
}

@test "F1: with no meta4 and a short download, the old ZIM is kept" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  export FAKE_WGET_META_FAIL=1 FAKE_WGET_SHORT="$WP_NEW"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_zim_unchanged "$WP_OLD"
}

@test "F2: a failure on the first ZIM does not mark the second one failed" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  make_local_zim "$WT_OLD"
  export FAKE_WGET_CORRUPT="$WP_NEW"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  assert_zim_unchanged "$WP_OLD"
  cmp "$ZIMS/$WT_NEW" "$(remote_file "$WT_REMOTE")"
  refute_exists "$ZIMS/$WT_OLD"
}

@test "F3: a checksum failure leaves no 0-byte ZIM behind" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  printf 'X' | dd of="$ZIMS/$WP_NEW" bs=1 seek=10 conv=notrunc status=none
  export FAKE_WGET_CORRUPT="$WP_NEW"
  run_updater -f -d "$ZIMS"
  run find "$ZIMS" -type f -empty
  assert_output ''
}

@test "F4: -f in dry-run writes no .sha256 into the ZIM dir" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  local before
  before="$(zim_dir_snapshot)"
  run_updater -f "$ZIMS"
  assert_success
  assert_equal "$(zim_dir_snapshot)" "$before"
}

@test "F4: a failed meta4 fetch does not write an empty-hash .sha256" {
  make_local_zim "$WP_OLD"
  export FAKE_WGET_META_FAIL=1
  run_updater -d "$ZIMS"
  # Without metadata the download cannot be verified (F1), so no checksum may be written at all
  refute_exists "$ZIMS/$WP_NEW.sha256"
  assert_exists "$ZIMS/$WP_OLD"
}

@test "F4: -f -d with a failed meta4 fetch keeps a good cached .sha256" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_sha256 "$WP_NEW"
  keep_copy "$WP_NEW.sha256"
  export FAKE_WGET_META_FAIL=1
  run_updater -f -d "$ZIMS"
  assert_zim_unchanged "$WP_NEW.sha256"
}

@test "F5: a file named like the new ZIM in the CWD does not suppress the download" {
  make_local_zim "$WP_OLD"
  printf 'unrelated' >"$RUN_DIR/$WP_NEW"
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_OLD"
  run cat "$RUN_DIR/$WP_NEW"
  assert_output 'unrelated'
}

@test "F5: with -t, a file named like the new ZIM in the CWD does not suppress the torrent" {
  make_local_zim "$WP_OLD"
  printf 'unrelated' >"$RUN_DIR/$WP_NEW"
  run_updater -d -t "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW.torrent" "$(remote_file "$WP_REMOTE.torrent")"
}

@test "F6: -f verifies an unmatched local ZIM against its own .sha256 in the ZIM dir" {
  make_local_zim orphan_test_2025-01.zim
  make_local_sha256 orphan_test_2025-01.zim
  run_updater -f "$ZIMS"
  assert_success
  assert_output --partial '- orphan_test_2025-01.zim:'
  assert_output --partial 'Cached Checksum Found'
}

###############################################################################
# H: correctness and operations

@test "H1: a nonexistent ZIM directory exits 2" {
  run_updater "$SANDBOX/does-not-exist"
  assert_failure 2
  assert_output --partial 'is not a directory'
}

@test "H1: a missing ZIM directory argument exits 2" {
  run_updater
  assert_failure 2
  assert_output --partial 'Kiwix ZIM Directory not provided'
}

@test "H1: an empty ZIM directory exits 1" {
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'No ZIMs found'
}

@test "H1: a failed download exits 1" {
  make_local_zim "$WP_OLD"
  export FAKE_WGET_CORRUPT="$WP_NEW"
  run_updater -d -c "$ZIMS"
  assert_failure 1
}

@test "H2: -c together with -t aborts with exit 2" {
  make_local_zim "$WP_OLD"
  run_updater -d -c -t "$ZIMS"
  assert_failure 2
  assert_output --partial 'Calculating Checksum not available with torrenting'
  run wget_downloads
  assert_output ''
}

@test "H3: self-update never moves download.log or kiwix-index into the script dir" {
  mkdir "$SANDBOX/bin/.git"
  export FAKE_GIT_MODE=other-branch
  make_local_zim "$WP_OLD"
  run_updater -U "$ZIMS"
  assert_success
  assert_output --partial 'You appear to be on a different branch'
  assert_exists "$RUN_DIR/download.log"
  assert_exists "$RUN_DIR/kiwix-index"
  refute_exists "$SANDBOX/bin/download.log"
  refute_exists "$SANDBOX/bin/kiwix-index"
  run download_log
  assert_line '3. Processing ZIM(s)...'
}

@test "H3: an up-to-date self-update check keeps download.log and kiwix-index in the run dir" {
  mkdir "$SANDBOX/bin/.git"
  export FAKE_GIT_MODE=current
  make_local_zim "$WP_OLD"
  run_updater -U "$ZIMS"
  assert_success
  assert_output --partial 'Version: Current'
  assert_exists "$RUN_DIR/download.log"
  assert_exists "$RUN_DIR/kiwix-index"
  refute_exists "$SANDBOX/bin/download.log"
  refute_exists "$SANDBOX/bin/kiwix-index"
}

@test "H5: -n without a value exits 2" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS" -n
  assert_failure 2
}

@test "H5: -n with a garbage value exits 2" {
  make_local_zim "$WP_OLD"
  run_updater -n banana "$ZIMS"
  assert_failure 2
}

@test "H5: -x with a garbage value exits 2" {
  make_local_zim "$WP_OLD"
  run_updater -x 12parsecs "$ZIMS"
  assert_failure 2
}

@test "H5: an unknown --option exits 2 with usage" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS" --bogus
  assert_failure 2
  assert_output --partial 'Usage:'
}

@test "H5: two positional arguments exit 2" {
  mkdir "$SANDBOX/other"
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS" "$SANDBOX/other"
  assert_failure 2
}

@test "H5: an invalid -l country code warns on stderr" {
  make_local_zim "$WP_OLD"
  run_updater --separate-stderr -l nope "$ZIMS"
  assert_success
  [[ "${stderr,,}" == *"country code"* ]]
}

@test "H6: a second instance on the same ZIM dir exits 75" {
  make_local_zim "$WP_OLD"
  exec 8<"$ZIMS"
  flock -n 8
  run_updater "$ZIMS"
  exec 8<&-
  assert_failure 75
  run wget_downloads
  assert_output ''
}

@test "H7: a missing wget exits 1 with a clear message" {
  make_tooldir wget
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'wget'
  refute_output --partial 'command not found'
}

###############################################################################
# M: medium

@test "M2: clear is not called when stdout is not a terminal" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  refute_nonempty "$FAKE_CLEAR_LOG"
}

###############################################################################
# N: new defects found while building the harness (not in the review table)

@test "N1: with GNU Wget2 the meta4 is read as metadata, not followed" {
  export FAKE_WGET_FLAVOR=wget2
  make_local_zim "$WP_OLD"
  run_updater -d -c "$ZIMS"
  assert_success
  assert_output --partial 'Download (mirror) : https://mirror.kiwix.test/'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_OLD"
}

@test "N2: -f -d never deletes an unmatched ZIM that has a valid own checksum" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_zim zzz_orphan_test_2025-01.zim "$(head -c 2048 < <(yes 'orphan payload'))"
  make_local_sha256 zzz_orphan_test_2025-01.zim
  keep_copy "zzz_orphan_test_2025-01.zim"
  run_updater -f -d "$ZIMS"
  assert_zim_unchanged "zzz_orphan_test_2025-01.zim"
  assert_output --partial 'Checksum passed'
  run wget_downloads
  assert_output ''
}

@test "N2: -f -d reports a corrupt unmatched ZIM but keeps it (nothing to replace it with)" {
  make_local_zim orphan_test_2025-01.zim 'orphan payload'
  make_local_sha256 orphan_test_2025-01.zim
  printf 'tampered' >"$ZIMS/orphan_test_2025-01.zim"
  keep_copy "orphan_test_2025-01.zim"
  keep_copy "orphan_test_2025-01.zim.sha256"
  run_updater -f -d "$ZIMS"
  assert_output --partial 'no online version to replace it with'
  assert_zim_unchanged "orphan_test_2025-01.zim"
  assert_zim_unchanged "orphan_test_2025-01.zim.sha256"
  run wget_downloads
  assert_output ''
}

@test "N3: -f -d with a failed meta4 fetch never deletes a good ZIM" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_sha256 "$WP_NEW"
  export FAKE_WGET_META_FAIL=1
  run_updater -f -d "$ZIMS"
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  # Since R9 the cached .sha256 is used when the metadata is unavailable
  assert_output --partial 'verifying against the cached checksum'
  assert_output --partial 'Checksum passed'
}

@test "N3: -f -d with a failed meta4 fetch and no cached checksum keeps the ZIM and reports it" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  export FAKE_WGET_META_FAIL=1
  run_updater -f -d "$ZIMS"
  assert_failure 1
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  assert_output --partial "cannot verify $WP_NEW"
  refute_output --partial 'Checksum passed'
}

@test "N4: -S stops new .sha256 files from being written" {
  make_local_zim "$WP_OLD"
  run_updater -d -S "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_NEW.sha256"
}

@test "N5: -f checks an outdated ZIM against its own online checksum, not the new release's" {
  use_fixture_copy
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  # The older release's checksum is still published next to the new one.
  (cd "$ZIMS" && sha256sum "$WP_OLD") >"$(remote_file "zim/wikipedia/$WP_OLD.sha256")"
  run_updater -f -d "$ZIMS"
  assert_zim_unchanged "$WP_OLD"
  refute_output --partial 'removing corrupt file'
}

@test "N1: with GNU Wget2 every meta4 request carries --no-metalink" {
  export FAKE_WGET_FLAVOR=wget2
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  grep -qF '.meta4' "$FAKE_WGET_LOG"
  run bash -c 'grep -F .meta4 "$1" | grep -v -e --no-metalink' _ "$FAKE_WGET_LOG"
  assert_output ''
}

@test "N1: with wget 1.x no meta4 request carries --no-metalink" {
  export FAKE_WGET_FLAVOR=wget1
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  grep -qF '.meta4' "$FAKE_WGET_LOG"
  run grep -e --no-metalink "$FAKE_WGET_LOG"
  assert_output ''
}

@test "N5: -f reports a corrupt outdated ZIM against its own online checksum and keeps it" {
  use_fixture_copy
  make_local_zim "$WP_OLD"
  (cd "$ZIMS" && sha256sum "$WP_OLD") >"$(remote_file "zim/wikipedia/$WP_OLD.sha256")"
  printf 'tampered' >>"$ZIMS/$WP_OLD"
  keep_copy "$WP_OLD"
  run_updater -f -d "$ZIMS"
  assert_output --partial 'a normal update run (without -f) will replace it'
  assert_zim_unchanged "$WP_OLD"
  run wget_downloads
  assert_output ''
}

@test "N5: -f -d stores the outdated ZIM's own online checksum for offline use" {
  use_fixture_copy
  make_local_zim "$WP_OLD"
  (cd "$ZIMS" && sha256sum "$WP_OLD") >"$(remote_file "zim/wikipedia/$WP_OLD.sha256")"
  run_updater -f -d "$ZIMS"
  assert_output --partial 'Checksum passed'
  run cat "$ZIMS/$WP_OLD.sha256"
  assert_output "$(cut -d' ' -f1 "$(remote_file "zim/wikipedia/$WP_OLD.sha256")") $WP_OLD"
}
