#!/usr/bin/env bats
# The online catalog: fetching it, caching it in kiwix-index in the run directory (-g fetches it again), and
# catalogs the script cannot use.

setup() {
  load 'helpers/common'
  common_setup
}

INDEX="kiwix-index"

# True if the catalog was requested since the wget log was last cleared.
catalog_fetched() {
  grep -qF opds "$FAKE_WGET_LOG"
}

# Rewrite the date line of the cached index to the given `date -d` string.
age_index() {
  local date
  date="$(date -u -d "$1" +%Y-%m-%dT%H:%M:%S)"
  sed -i "1s/.*/$date/" "$RUN_DIR/$INDEX"
}

###############################################################################
# The cached index

@test "the index has the date on its first line and one link line per ZIM (H4)" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  run head -1 "$RUN_DIR/$INDEX"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$'
  run tail -n +2 "$RUN_DIR/$INDEX"
  assert_output "$(grep -i 'application/x-zim' "$FAKE_FIXTURES/catalog.xml" | sed 's/^[[:space:]]*//')"
  run ls -A "$RUN_DIR"
  assert_output "$(printf 'download.log\n%s' "$INDEX")"
}

@test "a fresh cached index is reused without fetching the catalog (H4)" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  catalog_fetched
  cp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  : >"$FAKE_WGET_LOG"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial "Found $(catalog_zim_count) files online"
  run catalog_fetched
  assert_failure
  cmp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
}

@test "-g fetches the catalog again despite a fresh index (H4)" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater "$ZIMS"
  assert_success
  : >"$FAKE_WGET_LOG"
  run_updater -g "$ZIMS"
  assert_success
  run grep -c opds "$FAKE_WGET_LOG"
  assert_output '1'
}

@test "an index older than a day is refreshed (H4)" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  age_index '2 days ago'
  : >"$FAKE_WGET_LOG"
  run_updater "$ZIMS"
  assert_success
  catalog_fetched
  run date -u -d "$(head -1 "$RUN_DIR/$INDEX")" +%s
  ((output > $(date -u -d '1 hour ago' +%s)))
}

@test "a cached index without links is not reused (H4)" {
  make_local_zim "$WP_OLD"
  date -u +%Y-%m-%dT%H:%M:%S >"$RUN_DIR/$INDEX"
  run_updater "$ZIMS"
  assert_success
  catalog_fetched
  assert_output --partial "Found $(catalog_zim_count) files online"
}

###############################################################################
# A catalog that cannot be fetched or used

@test "a failed catalog fetch exits 1 and caches no kiwix-index (H4)" {
  make_local_zim "$WP_OLD"
  export FAKE_WGET_CATALOG_FAIL=1
  run_updater "$ZIMS"
  assert_failure 1
  refute_exists "$RUN_DIR/kiwix-index"
}

@test "a failed -g refetch exits 1 and leaves the existing index untouched (H4)" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  cp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  export FAKE_WGET_CATALOG_FAIL=1
  run_updater -g "$ZIMS"
  assert_failure 1
  assert_output --partial 'Could not fetch the online catalog'
  cmp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  run download_log
  assert_output --partial 'Could not fetch the online catalog'
}

@test "a failed refresh of a stale index exits 1 and leaves it untouched (H4)" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  age_index '2 days ago'
  cp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  export FAKE_WGET_CATALOG_FAIL=1
  run_updater "$ZIMS"
  assert_failure 1
  cmp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  run ls -A "$RUN_DIR"
  assert_output "$(printf 'download.log\n%s' "$INDEX")"
}

@test "a catalog without an <updated> date exits 1 and is not cached (H4)" {
  use_fixture_copy
  sed -i '/<updated>/d' "$FAKE_FIXTURES/catalog.xml"
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'no <updated> date'
  refute_exists "$RUN_DIR/$INDEX"
}

@test "a catalog without ZIM links exits 1 and does not replace the index (H4)" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  cp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
  use_fixture_copy
  sed -i '/application\/x-zim/d' "$FAKE_FIXTURES/catalog.xml"
  run_updater -g "$ZIMS"
  assert_failure 1
  assert_output --partial 'No ZIM URLs found'
  cmp "$RUN_DIR/$INDEX" "$SANDBOX/index.orig"
}

@test "a catalog without ZIM URLs exits 1 (H1)" {
  use_fixture_copy
  printf '<feed>\n  <updated>__NOW__</updated>\n</feed>\n' >"$FAKE_FIXTURES/catalog.xml"
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'No ZIM URLs found'
}

@test "a catalog without remote files exits 1 (H1)" {
  use_fixture_copy
  printf '<feed>\n  <updated>__NOW__</updated>\n</feed>\n' >"$FAKE_FIXTURES/catalog.xml"
  add_root_level_catalog_entry
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'Could not find any remote files'
}

@test "a catalog with more than one download host exits 1" {
  use_fixture_copy
  sed -i '0,/https:\/\/download\.kiwix\.test\/zim\//s##https://other.kiwix.test/zim/#' "$FAKE_FIXTURES/catalog.xml"
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'Too many zim base urls found'
  run download_log
  assert_output --partial 'Too many zim base urls found'
}

@test "a catalog entry outside any category aborts with a red array-length mismatch (M3)" {
  add_root_level_catalog_entry
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'CRITICAL ERROR!'
  assert_output --partial $'\033[0;31mParsed array lengths did not match. Aborting to prevent data loss'
  run download_log
  assert_output --partial 'Parsed array lengths did not match'
}
