#!/usr/bin/env bats
# Phase 3: structure (source guard, main), removal of the legacy kiwix-zim.sh name.

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
}

OLD_WP=wikipedia_en_test_2025-12.zim

@test "M5: running under the legacy name kiwix-zim.sh no longer exits 2" {
  make_local_zim "$OLD_WP"
  cp "$SCRIPT_COPY" "$SANDBOX/bin/kiwix-zim.sh"
  cd "$RUN_DIR"
  run bash "$SANDBOX/bin/kiwix-zim.sh" "$ZIMS"
  assert_success
  refute_output --partial 'deprecated'
  run download_log
  refute_output --partial 'deprecated'
}
