#!/usr/bin/env bats
# Characterization: command line, banner, self-update detection, index cache.

setup() {
  load 'helpers/common'
  common_setup
}

@test "cli: -h prints usage and exits 0" {
  run_updater -h
  assert_success
  assert_line --index 0 'Usage: ./kiwix-zim-updater.sh <options> /full/path/'
  assert_output --partial '-d, --disable-dry-run'
  run cat "$FAKE_WGET_LOG"
  assert_output ''
}

@test "cli: -v prints the version and exits 0" {
  run_updater -v
  assert_success
  assert_output "$(grep -oP '^VER="\K[^"]+' "$SCRIPT_COPY")"
  refute_output ''
}

@test "cli: default run is a dry-run and says so" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'DRY-RUN/SIMULATION'
  assert_output --partial '- ENABLED -'
  refute_output --partial '- DISABLED -'
}

@test "cli: -d disables the dry-run banner" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial '- DISABLED -'
  assert_output --partial '!!! Caution !!!'
}
