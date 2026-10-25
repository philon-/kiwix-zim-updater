#!/usr/bin/env bats
# --library: a kiwix library XML file kept in sync with the verified ZIMs, for kiwix-serve --monitorLibrary.
# kiwix-manage is a stub (test/helpers/bin/kiwix-manage) that writes the real format.

setup() {
  load 'helpers/common'
  common_setup
  LIB="$ZIMS/library.xml"
}

# Paths listed in the library, one per line, sorted
listed() {
  grep -o 'path="[^"]*"' "$LIB" | sed 's/^path="//; s/"$//' | LC_ALL=C sort
}

# The library's modification time (to the nanosecond) and size
lib_stamp() {
  stat -c '%y %s' "$LIB"
}

# True once the library's stamp differs from <stamp>. The script touches a library it wrote again 2s later.
lib_touched_since() {
  [[ "$(lib_stamp)" != "$1" ]]
}

# True once every delayed touch has happened: no process (the script's background subshell, its touch) names the
# library any more. A run that writes the library twice leaves two of them.
lib_settled() {
  ! pgrep -f -- "$LIB" >/dev/null
}

@test "library: an update lists the new ZIM, not the purged one, and never a .part file" {
  make_local_zim "$WP_OLD"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  assert_output --partial "Library: $LIB now lists 1 ZIM(s)"
  run listed
  assert_output "$WP_NEW"
}

@test "library: the new ZIM is listed before the old one is purged" {
  make_local_zim "$WP_OLD"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  # The new ZIM was added to the library at a moment when the old one still existed
  run grep -E "^$WP_NEW:.* $WP_OLD( |\$)" "$FAKE_KIWIX_MANAGE_SEEN"
  assert_success
}

@test "library: paths are relative to the library file, so other containers can mount it elsewhere" {
  make_local_zim "$WP_OLD"
  run_updater -d --library "$LIB" "$ZIMS"
  run grep -c 'path="/' "$LIB"
  assert_output '0'
}

@test "library: the file is rewritten in place (kiwix-serve 3.8 loses a renamed file)" {
  make_local_zim "$WP_OLD"
  printf '<library version="20110515">\n</library>\n' >"$LIB"
  local inode
  inode="$(stat -c %i "$LIB")"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  assert_equal "$(stat -c %i "$LIB")" "$inode"
  run listed
  assert_output "$WP_NEW"
  run ls "$ZIMS"
  refute_output --partial '.tmp.'
}

@test "library: an unchanged library is not written again" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  wait_until 10 lib_settled
  local before
  before="$(lib_stamp)"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  refute_output --partial 'Library:'
  assert_equal "$(lib_stamp)" "$before"
}

@test "library: a changed library is touched again shortly after it was written" {
  make_local_zim "$WP_OLD"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  local first
  first="$(lib_stamp)"
  wait_until 10 lib_touched_since "$first"
}

@test "library: the delayed touch does not keep the ZIM directory locked" {
  make_local_zim "$WP_OLD"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  refute_output --partial 'Another instance is already running'
}

@test "library: a dry-run creates and changes nothing" {
  make_local_zim "$WP_OLD"
  run_updater --library "$LIB" "$ZIMS"
  assert_success
  refute_exists "$LIB"
  refute_nonempty "$FAKE_KIWIX_MANAGE_LOG"
}

@test "library: an unreadable ZIM is reported and left out, the others are listed" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_zim orphan_test_2025-01.zim 'BADZIM not really a ZIM'
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  assert_output --partial 'orphan_test_2025-01.zim could not be read by kiwix-manage and is left out'
  run listed
  assert_output "$WP_NEW"
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
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_zim small_test_2025-01.zim
  touch "$ZIMS/.~lock.small_test_2025-01.zim"
  export FAKE_WGET_NETFAIL=small_test
  run_updater -d --library "$LIB" "$ZIMS"
  run listed
  assert_output "$WP_NEW"
}

@test "library: a failed download leaves the library listing the old ZIM" {
  make_local_zim "$WP_OLD"
  export FAKE_WGET_FAIL="$WP_NEW"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_failure 1
  run listed
  assert_output "$WP_OLD"
}

@test "library: an internet outage leaves the library untouched" {
  make_local_zim "$WP_OLD"
  run_updater -d --library "$LIB" "$ZIMS"
  assert_success
  wait_until 10 lib_settled
  cp "$LIB" "$SANDBOX/lib.orig"
  local before
  before="$(lib_stamp)"
  export FAKE_WGET_CATALOG_FAIL=1
  run_updater -d -g --library "$LIB" "$ZIMS"
  assert_failure 1
  cmp "$LIB" "$SANDBOX/lib.orig"
  assert_equal "$(lib_stamp)" "$before"
}

@test "library: a relative --library path is resolved against the current directory" {
  make_local_zim "$WP_OLD"
  run_updater -d --library lib.xml "$ZIMS"
  assert_success
  assert_exists "$RUN_DIR/lib.xml"
  run grep -o 'path="[^"]*"' "$RUN_DIR/lib.xml"
  assert_output "path=\"../zims/$WP_NEW\""
}

@test "library: --library needs a value" {
  make_local_zim "$WP_OLD"
  run_updater -d "$ZIMS" --library
  assert_failure 2
  run_updater -d --library -c "$ZIMS"
  assert_failure 2
}

@test "library: kiwix-manage is only required with --library" {
  make_tooldir kiwix-manage
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater "$ZIMS"
  assert_success
  PATH="$TOOLDIR" run_updater --library "$LIB" "$ZIMS"
  assert_failure 1
  assert_output --partial 'kiwix-manage'
}
