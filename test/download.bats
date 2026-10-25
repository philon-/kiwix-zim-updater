#!/usr/bin/env bats
# Characterization: dry-run safety, downloading, purging, -n/-x/-p/-c/-t.

setup() {
  load 'helpers/common'
  common_setup
}

@test "download: default dry-run changes nothing in the ZIM dir and downloads nothing" {
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

@test "download: dry-run still fetches only the catalog and metadata" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  # The wget flavour probe (--version) makes no request; ignore it.
  run grep -vx -- '--version' "$FAKE_WGET_LOG"
  assert_line --index 0 --partial 'opds.library.kiwix.org'
  assert_line --index 1 --partial "$WP_REMOTE.meta4"
  refute_line --index 2 --regexp '.'
}

@test "download: -d replaces the old ZIM with the verified new one" {
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

@test "download: -d updates several ZIMs in one run" {
  make_local_zim "$WP_OLD"
  make_local_zim "$WT_OLD"
  run_updater -d "$ZIMS"
  assert_success
  run ls -A "$ZIMS"
  assert_output "$(printf '%s\n' "$WP_NEW" "$WP_NEW.sha256" "$WT_NEW" "$WT_NEW.sha256" | LC_ALL=C sort)"
  cmp "$ZIMS/$WT_NEW" "$(remote_file "$WT_REMOTE")"
}

@test "download: -d -c verifies the checksum, then purges the old ZIM" {
  make_local_zim "$WP_OLD"
  run_updater -d -c "$ZIMS"
  assert_success
  assert_output --partial 'Checksum passed'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_OLD"
}

@test "download: -d -c with a corrupt download removes the new ZIM and keeps the old one" {
  make_local_zim "$WP_OLD"
  export FAKE_WGET_CORRUPT="$WP_NEW"
  run_updater -d -c "$ZIMS"
  assert_output --partial 'Checksum failed, removing corrupt download'
  assert_exists "$ZIMS/$WP_OLD"
  refute_exists "$ZIMS/$WP_NEW"
  refute_exists "$ZIMS/$WP_NEW.sha256"
  run find "$ZIMS" -name '.~lock.*'
  assert_output ''
  run download_log
  assert_line ' !!! DOWNLOAD FAILED !!!'
}

@test "download: -d resumes an interrupted download (lock file present)" {
  make_local_zim "$WP_OLD"
  head -c 100 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW"
  : >"$ZIMS/.~lock.$WP_NEW"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial 'ZIM download was interrupted. Continuing...'
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_OLD"
  refute_exists "$ZIMS/.~lock.$WP_NEW"
}

@test "download: -d -p keeps the old ZIM next to the new one" {
  make_local_zim "$WP_OLD"
  run_updater -d -p "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  assert_exists "$ZIMS/$WP_OLD"
  run find "$ZIMS" -name '.~lock.*'
  assert_output ''
}

@test "download: -n skips updates smaller than the minimum size" {
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

@test "download: -n lets larger updates through" {
  make_local_zim small_test_2025-11.zim
  make_local_zim big_test_2026-01.zim
  run_updater -n 2K "$ZIMS"
  assert_success
  assert_output --partial 'Update skipped (minimum'
  assert_output --partial 'Update found! --> 2026-03'
}

@test "download: -x skips updates larger than the maximum size" {
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

@test "download: -d -t downloads only the .torrent and keeps the old ZIM" {
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

@test "download: a second -t run sees the torrent and downloads nothing" {
  make_local_zim "$WP_OLD"
  cp "$(remote_file "$WP_REMOTE.torrent")" "$ZIMS/$WP_NEW.torrent"
  run_updater -d -t "$ZIMS"
  assert_success
  assert_output --partial 'Torrent already downloaded'
  run wget_downloads
  assert_output ''
}

@test "download: a mirror-less meta4 falls back to the direct URL" {
  use_fixture_copy
  sed -i '/priority="1"/d' "$(remote_file "$WP_REMOTE.meta4")"
  make_local_zim "$WP_OLD"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial "Download (direct) : https://download.kiwix.test/$WP_REMOTE"
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
}

@test "download: -l passes a valid country code to the meta4 request" {
  make_local_zim "$WP_OLD"
  run_updater -l SE "$ZIMS"
  assert_success
  run grep -c 'meta4?country=SE' "$FAKE_WGET_LOG"
  assert_output '1'
}

@test "download: -l with an invalid code falls back and logs it" {
  make_local_zim "$WP_OLD"
  run_updater -l nope "$ZIMS"
  assert_success
  run download_log
  assert_line 'Invalid country code, falling back to default kiwix behavior'
  run grep -c 'meta4?country=$' "$FAKE_WGET_LOG"
  assert_output '1'
}

@test "download: -t with a failed torrent download leaves no partial .torrent" {
  make_local_zim "$WP_OLD"
  export FAKE_WGET_FAIL="$WP_NEW.torrent"
  run_updater -d -t "$ZIMS"
  assert_output --partial 'Torrent download failed'
  refute_exists "$ZIMS/$WP_NEW.torrent"
  assert_exists "$ZIMS/$WP_OLD"
}
