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
