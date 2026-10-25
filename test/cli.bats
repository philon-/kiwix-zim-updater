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
  assert_output '3.5'
}

@test "cli: default run is a dry-run and says so" {
  make_local_zim wikipedia_en_test_2026-01.zim --from-remote zim/wikipedia/wikipedia_en_test_2026-01.zim
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'DRY-RUN/SIMULATION'
  assert_output --partial '- ENABLED -'
  refute_output --partial '- DISABLED -'
}

@test "cli: -d disables the dry-run banner" {
  make_local_zim wikipedia_en_test_2026-01.zim --from-remote zim/wikipedia/wikipedia_en_test_2026-01.zim
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial '- DISABLED -'
  assert_output --partial '!!! Caution !!!'
}

@test "cli: without a .git next to the script, self-update is skipped and git never runs" {
  make_local_zim wikipedia_en_test_2026-01.zim --from-remote zim/wikipedia/wikipedia_en_test_2026-01.zim
  run_updater -U "$ZIMS"
  assert_success
  assert_output --partial 'Git Clone Not Detected: Skipping Update Check'
  run cat "$FAKE_GIT_LOG"
  assert_output ''
}

@test "cli: -u skips the self-update check" {
  make_local_zim wikipedia_en_test_2026-01.zim --from-remote zim/wikipedia/wikipedia_en_test_2026-01.zim
  run_updater -u "$ZIMS"
  assert_success
  assert_output --partial 'Check Skipped'
}

@test "cli: the catalog is fetched once and cached in kiwix-index in the CWD" {
  make_local_zim wikipedia_en_test_2026-01.zim --from-remote zim/wikipedia/wikipedia_en_test_2026-01.zim
  run_updater "$ZIMS"
  assert_success
  assert_exists "$RUN_DIR/kiwix-index"
  run head -1 "$RUN_DIR/kiwix-index"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$'
  run grep -c 'application/x-zim' "$RUN_DIR/kiwix-index"
  assert_output '4'

  : >"$FAKE_WGET_LOG"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'Found 4 files online'
  run grep -c opds "$FAKE_WGET_LOG"
  assert_output '0'
}

@test "cli: -g forces a fresh catalog fetch despite a valid cache" {
  make_local_zim wikipedia_en_test_2026-01.zim --from-remote zim/wikipedia/wikipedia_en_test_2026-01.zim
  run_updater "$ZIMS"
  assert_success
  : >"$FAKE_WGET_LOG"
  run_updater -g "$ZIMS"
  assert_success
  run grep -c opds "$FAKE_WGET_LOG"
  assert_output '1'
}

@test "cli: a catalog entry outside any category aborts with an array length mismatch" {
  use_fixture_copy
  sed -i 's#</feed>#  <entry>\n    <link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" href="https://download.kiwix.test/zim/rootlevel_test_2026-01.zim.meta4" length="1024" />\n  </entry>\n</feed>#' "$FAKE_FIXTURES/catalog.xml"
  make_local_zim wikipedia_en_test_2026-01.zim --from-remote zim/wikipedia/wikipedia_en_test_2026-01.zim
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'CRITICAL ERROR!'
  assert_output --partial 'Parsed array lengths did not match. Aborting to prevent data loss'
}
