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

###############################################################################
# M: medium

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
