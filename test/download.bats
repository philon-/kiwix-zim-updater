#!/usr/bin/env bats
# Downloading updates: dry-run, replacing and purging, -c, failed downloads, -n/-x, -t, mirrors and wget options.

setup() {
  load 'helpers/common'
  common_setup
}

###############################################################################
# Dry-run

@test "default dry-run changes nothing in the ZIM dir and downloads nothing" {
  make_local_zim "$WP_OLD"
  make_local_zim "$WT_OLD"
  make_local_zim small_test_2025-11.zim
  local before
  before="$(zim_dir_snapshot)"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '*** Simulated *** New zim exists, old zim purged'
  [[ "$(zim_dir_snapshot)" == "$before" ]]
  run wget_downloads
  assert_output ''
}

@test "dry-run still fetches only the catalog and metadata" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  # The wget flavour probe (--version) makes no request; ignore it.
  run grep -vx -- '--version' "$FAKE_WGET_LOG"
  assert_line --index 0 --partial 'opds.library.kiwix.org'
  assert_line --index 1 --partial "$WP_REMOTE.meta4"
  refute_line --index 2 --regexp '.'
}

@test "a failed download in dry-run is never attempted and exits 0" {
  make_local_zim "$WP_OLD"
  export FAKE_WGET_FAIL="$WP_NEW"
  run_updater "$ZIMS"
  assert_success
}

###############################################################################
# Updating

@test "-d replaces the old ZIM with the verified new one" {
  make_local_zim "$WP_OLD"
  make_local_sha256 "$WP_OLD"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial "Download (mirror) : https://mirror.kiwix.test/$WP_REMOTE"
  assert_output --partial 'New ZIM downloaded successfully. Old ZIM purged.'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_OLD"
  refute_exists "$ZIMS/$WP_OLD.sha256"
  run cat "$ZIMS/$WP_NEW.sha256"
  assert_output "$(cut -d' ' -f1 <"$(remote_file "$WP_REMOTE.sha256")") $WP_NEW"
  (cd "$ZIMS" && sha256sum --status -c "$WP_NEW.sha256")
  run find "$ZIMS" -name '.~lock.*'
  assert_output ''
  # Downloads are staged in a .part file and renamed once verified
  assert_single_download "$ZIMS/$WP_NEW.part" "https://mirror.kiwix.test/$WP_REMOTE"
}

@test "-d updates several ZIMs in one run" {
  make_local_zim "$WP_OLD"
  make_local_zim "$WT_OLD"
  run_updater -d "$ZIMS"
  assert_success
  run ls -A "$ZIMS"
  assert_output "$(printf '%s\n' "$WP_NEW" "$WP_NEW.sha256" "$WT_NEW" "$WT_NEW.sha256" | LC_ALL=C sort)"
  cmp "$ZIMS/$WT_NEW" "$(remote_file "$WT_REMOTE")"
}

@test "-d -p keeps the old ZIM next to the new one" {
  make_local_zim "$WP_OLD"
  run_updater -d -p "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  assert_exists "$ZIMS/$WP_OLD"
  run find "$ZIMS" -name '.~lock.*'
  assert_output ''
}

@test "a file named like the new ZIM in the CWD does not suppress the download (F5)" {
  make_local_zim "$WP_OLD"
  printf 'unrelated' >"$RUN_DIR/$WP_NEW"
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_OLD"
  run cat "$RUN_DIR/$WP_NEW"
  assert_output 'unrelated'
}

@test "with -t, a file named like the new ZIM in the CWD does not suppress the torrent (F5)" {
  make_local_zim "$WP_OLD"
  printf 'unrelated' >"$RUN_DIR/$WP_NEW"
  run_updater -d -t "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW.torrent" "$(remote_file "$WP_REMOTE.torrent")"
}

###############################################################################
# -c: the checksum of a download

@test "-d -c verifies the checksum, writes the checksum file, then purges the old ZIM" {
  make_local_zim "$WP_OLD"
  run_updater -d -c "$ZIMS"
  assert_success
  assert_output --partial 'Checksum passed'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_NEW.part"
  refute_exists "$ZIMS/$WP_OLD"
  run cat "$ZIMS/$WP_NEW.sha256"
  assert_output "$(cut -d' ' -f1 "$(remote_file "$WP_REMOTE.sha256")") $WP_NEW"
}

@test "-d -c with a corrupt download removes it with its checksum file, keeps the old ZIM and exits 1 (H1)" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  export FAKE_WGET_CORRUPT="$WP_NEW"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  assert_output --partial 'Checksum failed, removing corrupt download'
  assert_zim_unchanged "$WP_OLD"
  refute_exists "$ZIMS/$WP_NEW"
  refute_exists "$ZIMS/$WP_NEW.part"
  refute_exists "$ZIMS/$WP_NEW.sha256"
  run find "$ZIMS" -name '.~lock.*'
  assert_output ''
  run download_log
  assert_line ' !!! DOWNLOAD FAILED !!!'
}

@test "-c keeps the old ZIM when the metadata has no sha256 to check the download against (R4)" {
  use_fixture_copy
  sed -i '/sha-256/d' "$(remote_file "$WP_REMOTE.meta4")"
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  run_updater -d -c "$ZIMS"
  assert_failure 1
  assert_output --partial "No valid sha256 published for $WP_NEW"
  refute_output --partial 'Old ZIM purged'
  assert_zim_unchanged "$WP_OLD"
}

@test "dry-run -c without a published sha256 only reports it (R4)" {
  use_fixture_copy
  sed -i '/sha-256/d' "$(remote_file "$WP_REMOTE.meta4")"
  make_local_zim "$WP_OLD"
  run_updater -c "$ZIMS"
  assert_success
  assert_output --partial 'the checksum could not be verified'
}

###############################################################################
# Failed downloads

@test "a failed download (wget exit 4) keeps the old ZIM, the next ZIM is still updated, exit 1 (F1)" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  make_local_zim "$WT_OLD"
  export FAKE_WGET_FAIL="$WP_NEW"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'One or more downloads failed'
  assert_zim_unchanged "$WP_OLD"
  cmp "$ZIMS/$WT_NEW" "$(remote_file "$WT_REMOTE")"
  refute_exists "$ZIMS/$WT_OLD"
  run download_log
  assert_line ' !!! DOWNLOAD FAILED !!!'
}

@test "a short download (wget exit 0) keeps the old ZIM and stays a .part file (F1)" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  export FAKE_WGET_SHORT="$WP_NEW"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_zim_unchanged "$WP_OLD"
  refute_exists "$ZIMS/$WP_NEW"
  assert_nonempty "$ZIMS/$WP_NEW.part"
}

@test "a corrupt download of the first ZIM does not mark the second one failed (F2)" {
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

###############################################################################
# -n/-x size limits

@test "-n skips updates smaller than the minimum size" {
  make_local_zim small_test_2025-11.zim
  local before
  before="$(zim_dir_snapshot)"
  run_updater -d -n 2K "$ZIMS"
  assert_success
  # numfmt prints the locale's decimal separator.
  assert_output --regexp 'Update skipped \(minimum: 2[.,]0Ki, download size: 1[.,]0Ki\)\. New version: 2025-12'
  run wget_downloads
  assert_output ''
  [[ "$(zim_dir_snapshot)" == "$before" ]]
}

@test "-n lets larger updates through" {
  make_local_zim small_test_2025-11.zim
  make_local_zim big_test_2026-01.zim
  run_updater -n 2K "$ZIMS"
  assert_success
  assert_output --partial 'Update skipped (minimum'
  assert_output --partial 'Update found! --> 2026-03'
}

@test "-x skips updates larger than the maximum size" {
  make_local_zim big_test_2026-01.zim
  local before
  before="$(zim_dir_snapshot)"
  run_updater -d -x 8K "$ZIMS"
  assert_success
  assert_output --regexp 'Update skipped \(maximum: 7[.,]9Ki, download size: 16Ki\)\. New version: 2026-03'
  run wget_downloads
  assert_output ''
  [[ "$(zim_dir_snapshot)" == "$before" ]]
}

###############################################################################
# -t: torrents

@test "-d -t downloads only the .torrent and keeps the old ZIM" {
  make_local_zim "$WP_OLD"
  run_updater -d -t "$ZIMS"
  assert_success
  assert_output --partial "Download (direct) : https://download.kiwix.test/$WP_REMOTE.torrent"
  cmp "$ZIMS/$WP_NEW.torrent" "$(remote_file "$WP_REMOTE.torrent")"
  assert_exists "$ZIMS/$WP_OLD"
  refute_exists "$ZIMS/$WP_NEW"
  refute_exists "$ZIMS/$WP_NEW.sha256"
  assert_single_download "$ZIMS/$WP_NEW.torrent" "https://download.kiwix.test/$WP_REMOTE.torrent"
}

@test "a second -t run sees the torrent and downloads nothing" {
  make_local_zim "$WP_OLD"
  cp "$(remote_file "$WP_REMOTE.torrent")" "$ZIMS/$WP_NEW.torrent"
  run_updater -d -t "$ZIMS"
  assert_success
  assert_output --partial 'Torrent already downloaded'
  run wget_downloads
  assert_output ''
}

@test "-t with a failed torrent download leaves no partial .torrent and exits 1" {
  make_local_zim "$WP_OLD"
  export FAKE_WGET_FAIL="$WP_NEW.torrent"
  run_updater -d -t "$ZIMS"
  assert_failure 1
  assert_output --partial 'Torrent download failed'
  refute_exists "$ZIMS/$WP_NEW.torrent"
  assert_exists "$ZIMS/$WP_OLD"
}

###############################################################################
# Mirrors, -l and the wget options

@test "network: every wget request carries connect/read timeouts and a retry limit" {
  make_local_zim "$WP_OLD"
  run_updater -d -f "$ZIMS"
  run_updater -d "$ZIMS"
  assert_success
  run bash -c 'grep -vx -- --version "$1" | grep -v -e "--connect-timeout=30 --read-timeout=300 --tries=3"' _ "$FAKE_WGET_LOG"
  assert_output ''
  grep -q -- '-O -' "$FAKE_WGET_LOG"
  grep -q -- "-O $ZIMS/$WP_NEW.part" "$FAKE_WGET_LOG"
}

@test "a mirror-less meta4 falls back to the direct URL" {
  use_fixture_copy
  sed -i '/priority="1"/d' "$(remote_file "$WP_REMOTE.meta4")"
  make_local_zim "$WP_OLD"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial "Download (direct) : https://download.kiwix.test/$WP_REMOTE"
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
}

@test "-l passes a valid country code to the meta4 request" {
  make_local_zim "$WP_OLD"
  run_updater -l SE "$ZIMS"
  assert_success
  run grep -c 'meta4?country=SE' "$FAKE_WGET_LOG"
  assert_output '1'
}

@test "-l with an invalid code warns on stderr, falls back and logs it (H5)" {
  make_local_zim "$WP_OLD"
  run_updater --separate-stderr -l nope "$ZIMS"
  assert_success
  [[ "${stderr,,}" == *"country code"* ]]
  run download_log
  assert_line 'Invalid country code, falling back to default kiwix behavior'
  run grep -c 'meta4?country=$' "$FAKE_WGET_LOG"
  assert_output '1'
}

@test "with GNU Wget2 the meta4 is read as metadata, not followed (N1)" {
  export FAKE_WGET_FLAVOR=wget2
  make_local_zim "$WP_OLD"
  run_updater -d -c "$ZIMS"
  assert_success
  assert_output --partial 'Download (mirror) : https://mirror.kiwix.test/'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_OLD"
}

@test "with GNU Wget2 every meta4 request carries --no-metalink (N1)" {
  export FAKE_WGET_FLAVOR=wget2
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  grep -qF '.meta4' "$FAKE_WGET_LOG"
  run bash -c 'grep -F .meta4 "$1" | grep -v -e --no-metalink' _ "$FAKE_WGET_LOG"
  assert_output ''
}

@test "with wget 1.x no meta4 request carries --no-metalink (N1)" {
  export FAKE_WGET_FLAVOR=wget1
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  grep -qF '.meta4' "$FAKE_WGET_LOG"
  run grep -e --no-metalink "$FAKE_WGET_LOG"
  assert_output ''
}

@test "with GNU Wget2 downloads also carry --no-metalink, so -O is always honoured (N1)" {
  export FAKE_WGET_FLAVOR=wget2
  make_local_zim "$WP_OLD"
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  run wget_downloads
  assert_output --partial -- '--no-metalink'
  run bash -c 'grep -e " -O " "$1" | grep -v -e " -O - " | grep -v -e --no-metalink' _ "$FAKE_WGET_LOG"
  assert_output ''
}
