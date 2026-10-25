#!/usr/bin/env bats
# Characterization: dry-run safety, downloading, purging, -n/-x/-p/-c/-t.

setup() {
  load 'helpers/common'
  common_setup
}

NEW_WP=wikipedia_en_test_2026-01.zim
OLD_WP=wikipedia_en_test_2025-12.zim
WP_REMOTE=zim/wikipedia/wikipedia_en_test_2026-01.zim

@test "download: default dry-run changes nothing in the ZIM dir and downloads nothing" {
  make_local_zim "$OLD_WP"
  make_local_zim wiktionary_fr_test_2026-02.zim
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
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_success
  # The wget flavour probe (--version) makes no request; ignore it.
  run grep -vx -- '--version' "$FAKE_WGET_LOG"
  assert_line --index 0 --partial 'opds.library.kiwix.org'
  assert_line --index 1 --partial "$WP_REMOTE.meta4"
  refute_line --index 2 --regexp '.'
}

@test "download: -d replaces the old ZIM with the verified new one" {
  make_local_zim "$OLD_WP"
  make_local_sha256 "$OLD_WP"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial 'Download (mirror) : https://mirror.kiwix.test/zim/wikipedia/wikipedia_en_test_2026-01.zim'
  assert_output --partial 'New ZIM downloaded successfully. Old ZIM purged.'
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$OLD_WP"
  refute_exists "$ZIMS/$OLD_WP.sha256"
  run cat "$ZIMS/$NEW_WP.sha256"
  assert_output "$(cut -d' ' -f1 <"$(remote_file "$WP_REMOTE.sha256")") $NEW_WP"
  (cd "$ZIMS" && sha256sum --status -c "$NEW_WP.sha256")
  run find "$ZIMS" -name '.~lock.*'
  assert_output ''
  run wget_downloads
  # Downloads are staged in a .part file and renamed once verified
  assert_output "--connect-timeout=30 --read-timeout=300 --tries=3 -q --show-progress --progress=bar:force -c -O $ZIMS/$NEW_WP.part https://mirror.kiwix.test/zim/wikipedia/wikipedia_en_test_2026-01.zim"
}

@test "download: -d updates several ZIMs in one run" {
  make_local_zim "$OLD_WP"
  make_local_zim wiktionary_fr_test_2026-02.zim
  run_updater -d "$ZIMS"
  assert_success
  run ls -A "$ZIMS"
  assert_output "$(printf '%s\n' "$NEW_WP" "$NEW_WP.sha256" wiktionary_fr_test_2026-02a.zim wiktionary_fr_test_2026-02a.zim.sha256 | LC_ALL=C sort)"
  cmp "$ZIMS/wiktionary_fr_test_2026-02a.zim" "$(remote_file zim/wiktionary/wiktionary_fr_test_2026-02a.zim)"
}

@test "download: -d -c verifies the checksum, then purges the old ZIM" {
  make_local_zim "$OLD_WP"
  run_updater -d -c "$ZIMS"
  assert_success
  assert_output --partial 'Checksum passed'
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$OLD_WP"
}

@test "download: -d -c with a corrupt download removes the new ZIM and keeps the old one" {
  make_local_zim "$OLD_WP"
  export FAKE_WGET_CORRUPT=wikipedia_en_test_2026-01
  run_updater -d -c "$ZIMS"
  assert_output --partial 'Checksum failed, removing corrupt download'
  assert_exists "$ZIMS/$OLD_WP"
  refute_exists "$ZIMS/$NEW_WP"
  refute_exists "$ZIMS/$NEW_WP.sha256"
  run find "$ZIMS" -name '.~lock.*'
  assert_output ''
  run download_log
  assert_line ' !!! DOWNLOAD FAILED !!!'
}

@test "download: -d resumes an interrupted download (lock file present)" {
  make_local_zim "$OLD_WP"
  head -c 100 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$NEW_WP"
  : >"$ZIMS/.~lock.$NEW_WP"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial 'ZIM download was interrupted. Continuing...'
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$OLD_WP"
  refute_exists "$ZIMS/.~lock.$NEW_WP"
}

@test "download: -d -p keeps the old ZIM next to the new one" {
  make_local_zim "$OLD_WP"
  run_updater -d -p "$ZIMS"
  assert_success
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
  assert_exists "$ZIMS/$OLD_WP"
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
  make_local_zim "$OLD_WP"
  run_updater -d -t "$ZIMS"
  assert_success
  assert_output --partial "Download (direct) : https://download.kiwix.test/$WP_REMOTE.torrent"
  cmp "$ZIMS/$NEW_WP.torrent" "$(remote_file "$WP_REMOTE.torrent")"
  assert_exists "$ZIMS/$OLD_WP"
  refute_exists "$ZIMS/$NEW_WP"
  refute_exists "$ZIMS/$NEW_WP.sha256"
  run wget_downloads
  assert_output "--connect-timeout=30 --read-timeout=300 --tries=3 -q --show-progress --progress=bar:force -c -O $ZIMS/$NEW_WP.torrent https://download.kiwix.test/$WP_REMOTE.torrent"
}

@test "download: a second -t run sees the torrent and downloads nothing" {
  make_local_zim "$OLD_WP"
  cp "$(remote_file "$WP_REMOTE.torrent")" "$ZIMS/$NEW_WP.torrent"
  run_updater -d -t "$ZIMS"
  assert_success
  assert_output --partial 'Torrent already downloaded'
  run wget_downloads
  assert_output ''
}

@test "download: a mirror-less meta4 falls back to the direct URL" {
  use_fixture_copy
  sed -i '/priority="1"/d' "$(remote_file "$WP_REMOTE.meta4")"
  make_local_zim "$OLD_WP"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial "Download (direct) : https://download.kiwix.test/$WP_REMOTE"
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
}

@test "download: -l passes a valid country code to the meta4 request" {
  make_local_zim "$OLD_WP"
  run_updater -l SE "$ZIMS"
  assert_success
  run grep -c 'meta4?country=SE' "$FAKE_WGET_LOG"
  assert_output '1'
}

@test "download: -l with an invalid code falls back and logs it" {
  make_local_zim "$OLD_WP"
  run_updater -l nope "$ZIMS"
  assert_success
  run download_log
  assert_line 'Invalid country code, falling back to default kiwix behavior'
  run grep -c 'meta4?country=$' "$FAKE_WGET_LOG"
  assert_output '1'
}

@test "download: -t with a failed torrent download leaves no partial .torrent" {
  make_local_zim "$OLD_WP"
  export FAKE_WGET_FAIL=wikipedia_en_test_2026-01.zim.torrent
  run_updater -d -t "$ZIMS"
  assert_output --partial 'Torrent download failed'
  refute_exists "$ZIMS/$NEW_WP.torrent"
  assert_exists "$ZIMS/$OLD_WP"
}
