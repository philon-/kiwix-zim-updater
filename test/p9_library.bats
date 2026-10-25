#!/usr/bin/env bats
# --library: a kiwix library XML file kept in sync with the verified ZIMs, for kiwix-serve --monitorLibrary.
# kiwix-manage is a stub (test/helpers/bin/kiwix-manage) that writes the real format.

setup() {
  load 'helpers/common'
  common_setup
  LIB="$ZIMS/library.xml"
}

W=wikipedia_en_test_2026-01.zim
WOLD=wikipedia_en_test_2025-01.zim
WREMOTE=zim/wikipedia/wikipedia_en_test_2026-01.zim

# Paths listed in the library, one per line, sorted
listed() {
  grep -o 'path="[^"]*"' "$LIB" | sed 's/^path="//; s/"$//' | LC_ALL=C sort
}

@test "library: an update lists the new ZIM, not the purged one, and never a .part file" {
  make_local_zim "$WOLD"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  assert_output --partial "Library: $LIB now lists 1 ZIM(s)"
  run listed
  assert_output "$W"
}

@test "library: the new ZIM is listed before the old one is purged" {
  make_local_zim "$WOLD"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  # The new ZIM was added to the library at a moment when the old one still existed
  run grep -E "^$W:.* $WOLD( |\$)" "$FAKE_KIWIX_MANAGE_SEEN"
  assert_success
}

@test "library: paths are relative to the library file, so other containers can mount it elsewhere" {
  make_local_zim "$WOLD"
  run_updater -d --library "$LIB" "$ZIMS"
  run grep -c 'path="/' "$LIB"
  assert_output '0'
}

@test "library: the file is rewritten in place (kiwix-serve 3.8 loses a renamed file)" {
  make_local_zim "$WOLD"
  printf '<library version="20110515">\n</library>\n' >"$LIB"
  local inode
  inode="$(stat -c %i "$LIB")"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  assert_equal "$(stat -c %i "$LIB")" "$inode"
  run listed
  assert_output "$W"
  run ls "$ZIMS"
  refute_output --partial '.tmp.'
}

@test "library: an unchanged library is not written again" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  sleep 3 # let the delayed touch of the first write happen
  local before
  before="$(stat -c '%Y %s' "$LIB")"
  sleep 1
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  refute_output --partial 'Library:'
  assert_equal "$(stat -c '%Y %s' "$LIB")" "$before"
}

@test "library: a changed library is touched again shortly after it was written" {
  make_local_zim "$WOLD"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  local first
  first="$(stat -c %Y "$LIB")"
  sleep 4
  [[ "$(stat -c %Y "$LIB")" -gt "$first" ]]
}

@test "library: the delayed touch does not keep the ZIM directory locked" {
  make_local_zim "$WOLD"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  run_updater -d --library "$LIB" "$ZIMS"
  refute_output --partial 'Another instance is already running'
  [[ "$status" -ne 75 ]]
}

@test "library: a dry-run creates and changes nothing" {
  make_local_zim "$WOLD"
  run_updater --library "$LIB" "$ZIMS"
  assert_success
  refute_exists "$LIB"
  refute_nonempty "$FAKE_KIWIX_MANAGE_LOG"
}

@test "library: an unreadable ZIM is reported and left out, the others are listed" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  make_local_zim orphan_test_2025-01.zim 'BADZIM not really a ZIM'
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  assert_output --partial 'orphan_test_2025-01.zim could not be read by kiwix-manage and is left out'
  run listed
  assert_output "$W"
}

@test "library: when no ZIM can be read the existing library is kept and the run exits 1" {
  make_local_zim orphan_test_2025-01.zim 'BADZIM not really a ZIM'
  printf '<library version="20110515">\n  <book id="x" path="kept.zim" />\n</library>\n' >"$LIB"
  cp "$LIB" "$SANDBOX/lib.orig"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_failure 1
  assert_output --partial 'no ZIM could be added'
  cmp "$LIB" "$SANDBOX/lib.orig"
}

@test "library: a ZIM behind an old-style lock is an unfinished download and not listed" {
  make_local_zim "$W" --from-remote "$WREMOTE"
  make_local_zim small_test_2025-01.zim
  touch "$ZIMS/.~lock.small_test_2025-01.zim"
  export FAKE_WGET_NETFAIL=small_test
  run_updater -d --library "$LIB" "$ZIMS"
  run listed
  assert_output "$W"
}

@test "library: a failed download leaves the library listing the old ZIM" {
  make_local_zim "$WOLD"
  export FAKE_WGET_FAIL="$W"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_failure 1
  run listed
  assert_output "$WOLD"
}

@test "library: an internet outage leaves the library untouched" {
  make_local_zim "$WOLD"
  run_updater -d --library "$LIB" "$ZIMS"
  sleep 3
  cp "$LIB" "$SANDBOX/lib.orig"
  local before
  before="$(stat -c %Y "$LIB")"
  export FAKE_WGET_CATALOG_FAIL=1
  run_updater -d -g --library "$LIB" "$ZIMS"
  assert_failure 1
  cmp "$LIB" "$SANDBOX/lib.orig"
  assert_equal "$(stat -c %Y "$LIB")" "$before"
}

@test "library: a relative --library path is resolved against the current directory" {
  make_local_zim "$WOLD"
  run_updater -d --library lib.xml "$ZIMS"
  assert_success
  assert_exists "$RUN_DIR/lib.xml"
  run grep -o 'path="[^"]*"' "$RUN_DIR/lib.xml"
  assert_output "path=\"../zims/$W\""
}

@test "library: --library needs a value" {
  make_local_zim "$WOLD"
  run_updater -d "$ZIMS" --library
  assert_failure 2
  run_updater -d --library -c "$ZIMS"
  assert_failure 2
}

@test "library: kiwix-manage is only required with --library" {
  make_tooldir kiwix-manage
  make_local_zim "$WOLD"
  PATH="$TOOLDIR" run_updater "$ZIMS"
  assert_success
  PATH="$TOOLDIR" run_updater --library "$LIB" "$ZIMS"
  assert_failure 1
  assert_output --partial 'kiwix-manage'
}
