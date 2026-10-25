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
