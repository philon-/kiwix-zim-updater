#!/usr/bin/env bats
# Phase 3: structure (source guard, main), removal of the legacy kiwix-zim.sh name.

setup() {
  load 'helpers/common'
  common_setup
}

@test "M5: running under the legacy name kiwix-zim.sh no longer exits 2" {
  make_local_zim "$WP_OLD"
  cp "$SCRIPT_COPY" "$SANDBOX/bin/kiwix-zim.sh"
  cd "$RUN_DIR"
  run bash "$SANDBOX/bin/kiwix-zim.sh" "$ZIMS"
  assert_success
  refute_output --partial 'deprecated'
  run download_log
  refute_output --partial 'deprecated'
}

@test "structure: sourcing the script defines main and the helpers without running anything" {
  local before
  before="$(cd "$SANDBOX" && find . -printf '%P\n' | LC_ALL=C sort)"
  run bash -c 'source "$1" && declare -F main master_scrape validate_zim_dir list_local_zims match_to_catalog self_update usage_example hash_matches write_checksum_file >/dev/null && echo sourced-ok' _ "$SCRIPT_COPY"
  assert_success
  assert_output 'sourced-ok'
  assert_equal "$(cd "$SANDBOX" && find . -printf '%P\n' | LC_ALL=C sort)" "$before"
  refute_nonempty "$FAKE_WGET_LOG"
  refute_nonempty "$FAKE_GIT_LOG"
}

@test "structure: sourcing does not change the caller's shell options" {
  run bash -c 'shopt -u nullglob; source "$1"; shopt -q nullglob && echo on || echo off' _ "$SCRIPT_COPY"
  assert_success
  assert_output 'off'
}
