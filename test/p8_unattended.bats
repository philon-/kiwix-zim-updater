#!/usr/bin/env bats
# Unattended operation: network limits, free-space reserve, behaviour without metadata.

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
}

W=wikipedia_en_test_2026-01.zim
WOLD=wikipedia_en_test_2025-01.zim
WREMOTE=zim/wikipedia/wikipedia_en_test_2026-01.zim

@test "network: every wget request carries connect/read timeouts and a retry limit" {
  make_local_zim "$WOLD"
  run_updater -d -f "$ZIMS"
  run_updater -d "$ZIMS"
  assert_success
  run bash -c 'grep -vx -- --version "$1" | grep -v -e "--connect-timeout=30 --read-timeout=300 --tries=3"' _ "$FAKE_WGET_LOG"
  assert_output ''
  grep -q -- '-O -' "$FAKE_WGET_LOG"
  grep -q -- "-O $ZIMS/$W.part" "$FAKE_WGET_LOG"
}

keep_copy() {
  cp "$ZIMS/$1" "$SANDBOX/$1.orig"
}

GiB=1073741824

@test "free space: a download that would leave less than --min-free (default 1Gi) is skipped, old ZIM kept" {
  make_local_zim "$WOLD"
  keep_copy "$WOLD"
  export FAKE_DF_AVAIL=$((GiB + 4095))
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'Download skipped, not enough free space'
  assert_output --partial 'must stay free (--min-free)'
  cmp "$ZIMS/$WOLD" "$SANDBOX/$WOLD.orig"
  [[ ! -e "$ZIMS/$W" ]]
  [[ ! -e "$ZIMS/$W.part" ]]
  run wget_downloads
  assert_output ''
}

@test "free space: exactly enough room for the download plus the reserve is fine" {
  make_local_zim "$WOLD"
  export FAKE_DF_AVAIL=$((GiB + 4096))
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
}

@test "free space: only the bytes still missing from a .part count" {
  make_local_zim "$WOLD"
  head -c 4000 "$(remote_file "$WREMOTE")" >"$ZIMS/$W.part"
  export FAKE_DF_AVAIL=$((GiB + 96))
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
}

@test "free space: --min-free sets the reserve, 0 disables it" {
  make_local_zim "$WOLD"
  export FAKE_DF_AVAIL=5000
  run_updater -d --min-free 0 "$ZIMS"
  assert_success
  cmp "$ZIMS/$W" "$(remote_file "$WREMOTE")"
}

@test "free space: --min-free 2Gi is honoured" {
  make_local_zim "$WOLD"
  export FAKE_DF_AVAIL=$((GiB + GiB / 2))
  run_updater -d --min-free 2Gi "$ZIMS"
  assert_failure 1
  assert_output --partial '2.0Gi must stay free'
  [[ ! -e "$ZIMS/$W.part" ]]
}

@test "free space: an invalid --min-free is a usage error" {
  make_local_zim "$WOLD"
  run_updater -d --min-free lots "$ZIMS"
  assert_failure 2
  run_updater -d "$ZIMS" --min-free
  assert_failure 2
}

@test "free space: a dry-run only warns" {
  make_local_zim "$WOLD"
  export FAKE_DF_AVAIL=100
  local before
  before="$(zim_dir_snapshot)"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '*** Simulated *** The download would be skipped: not enough free space'
  assert_equal "$(zim_dir_snapshot)" "$before"
}

@test "metadata outage: nothing is downloaded when the size cannot be verified, old ZIM kept" {
  make_local_zim "$WOLD"
  keep_copy "$WOLD"
  export FAKE_WGET_META_FAIL=1
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'Download skipped, metadata unavailable'
  run wget_downloads
  assert_output ''
  cmp "$ZIMS/$WOLD" "$SANDBOX/$WOLD.orig"
  [[ ! -e "$ZIMS/$W.part" ]]
}

@test "internet outage: a -d run fails with exit 1 and leaves the ZIM directory byte-for-byte unchanged" {
  make_local_zim "$WOLD"
  make_local_sha256 "$WOLD"
  printf 'interrupted' >"$ZIMS/$W.part"
  run_updater -d "$ZIMS"
  assert_success
  local before
  before="$(cd "$ZIMS" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)"
  export FAKE_WGET_CATALOG_FAIL=1 FAKE_WGET_META_FAIL=1 FAKE_WGET_NETFAIL=kiwix.test
  run_updater -d -g "$ZIMS"
  assert_failure 1
  assert_equal "$(cd "$ZIMS" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)" "$before"
  [[ -s "$RUN_DIR/kiwix-index" ]]
}

@test "internet outage: -f -d -c --clean-partials changes nothing either" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  make_local_sha256 "$W"
  make_local_zim "$WOLD"
  printf 'partial' >"$ZIMS/wikipedia_en_test_2025-06.zim.part"
  local before
  before="$(cd "$ZIMS" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)"
  export FAKE_WGET_CATALOG_FAIL=1 FAKE_WGET_META_FAIL=1 FAKE_WGET_NETFAIL=kiwix.test
  run_updater -f -d -c --clean-partials -g "$ZIMS"
  assert_failure 1
  assert_equal "$(cd "$ZIMS" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)" "$before"
}
