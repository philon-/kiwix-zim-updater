#!/usr/bin/env bats
# Unit tests: source the sandboxed script (the source guard keeps main from running) and call its helpers directly.

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
  source "$SCRIPT_COPY"
  ZIMPath="$ZIMS/"
  LOG_FILE="$RUN_DIR/download.log"
  INDEX_FILE="$RUN_DIR/kiwix-index"
}

# assert_newer <date> <other date> / refute_newer <date> <other date>
assert_newer() {
  run zim_is_newer "$1" "$2"
  assert_success
}

refute_newer() {
  run zim_is_newer "$1" "$2"
  assert_failure
}

###############################################################################
# zim_date

@test "zim_date: prints the YYYY-MM date of a ZIM name" {
  run zim_date wikipedia_en_all_maxi_2026-01.zim
  assert_output '2026-01'
}

@test "zim_date: keeps the letter suffix of a re-release" {
  run zim_date wiktionary_fr_test_2026-02a.zim
  assert_output '2026-02a'
}

@test "zim_date: only the date right before .zim counts" {
  run zim_date test_2025-12_2026-01.zim
  assert_output '2026-01'
}

@test "zim_date: prints nothing for a name without a date" {
  run zim_date no_date_here.zim
  assert_output ''
  run zim_date wikipedia_en_test_2026-01.zim.torrent
  assert_output ''
  run zim_date ''
  assert_output ''
}

###############################################################################
# zim_is_newer

@test "zim_is_newer: a later month of the same year is newer" {
  assert_newer 2026-02 2026-01
  refute_newer 2026-01 2026-02
}

@test "zim_is_newer: a later year is newer, whatever the months" {
  assert_newer 2026-01 2025-12
  refute_newer 2025-12 2026-01
}

@test "zim_is_newer: a letter suffix is newer than the plain month and older than the next month" {
  assert_newer 2026-02a 2026-02
  refute_newer 2026-02 2026-02a
  assert_newer 2026-03 2026-02a
  refute_newer 2026-02a 2026-03
  assert_newer 2026-02 2026-01b
  refute_newer 2026-01b 2026-02
}

@test "zim_is_newer: letter suffixes are ordered alphabetically" {
  assert_newer 2026-02b 2026-02a
  refute_newer 2026-02a 2026-02b
}

@test "zim_is_newer: equal dates are not newer" {
  refute_newer 2026-01 2026-01
  refute_newer 2026-02a 2026-02a
}

@test "zim_is_newer: an empty date is older than any date" {
  assert_newer 2026-01 ''
  refute_newer '' 2026-01
  refute_newer '' ''
}

###############################################################################
# hash_matches

# sha256_of <text> - the sha256 of a text, as stored in a .sha256 file
sha256_of() {
  printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
}

@test "hash_matches: true for the file's own hash" {
  make_local_zim small_test_2025-12.zim 'payload'
  run hash_matches small_test_2025-12.zim "$(sha256_of 'payload')"
  assert_success
}

@test "hash_matches: false for another hash" {
  make_local_zim small_test_2025-12.zim 'payload'
  run hash_matches small_test_2025-12.zim "$(sha256_of 'other payload')"
  assert_failure
}

@test "hash_matches: false for a missing file" {
  run hash_matches small_test_2025-12.zim "$(sha256_of 'payload')"
  assert_failure
  assert_output ''
}

@test "hash_matches: works with spaces in the name" {
  make_local_zim 'my small test_2025-12.zim' 'payload'
  run hash_matches 'my small test_2025-12.zim' "$(sha256_of 'payload')"
  assert_success
  run hash_matches 'my small test_2025-12.zim' "$(sha256_of 'other payload')"
  assert_failure
}

###############################################################################
# write_checksum_file

HASH=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

@test "write_checksum_file: writes '<hash> <name>' with -d" {
  DEBUG=0
  CHECKSUM_FILES=1
  run write_checksum_file small_test_2025-12.zim "$HASH"
  assert_success
  run cat "$ZIMS/small_test_2025-12.zim.sha256"
  assert_output "$HASH small_test_2025-12.zim"
  run find "$ZIMS" -name '*.tmp'
  assert_output ''
}

@test "write_checksum_file: replaces an existing checksum file and handles spaces in the name" {
  DEBUG=0
  CHECKSUM_FILES=1
  echo stale >"$ZIMS/my small test_2025-12.zim.sha256"
  run write_checksum_file 'my small test_2025-12.zim' "$HASH"
  assert_success
  run cat "$ZIMS/my small test_2025-12.zim.sha256"
  assert_output "$HASH my small test_2025-12.zim"
  run find "$ZIMS" -name '*.tmp'
  assert_output ''
}

@test "write_checksum_file: writes nothing in dry-run" {
  DEBUG=1
  CHECKSUM_FILES=1
  run write_checksum_file small_test_2025-12.zim "$HASH"
  assert_success
  run ls -A "$ZIMS"
  assert_output ''
}

@test "write_checksum_file: writes nothing with -S" {
  DEBUG=0
  CHECKSUM_FILES=0
  run write_checksum_file small_test_2025-12.zim "$HASH"
  assert_success
  run ls -A "$ZIMS"
  assert_output ''
}

@test "write_checksum_file: writes nothing for a hash that is not 64 lowercase hex digits" {
  local bad
  DEBUG=0
  CHECKSUM_FILES=1
  for bad in '' 'abc' "${HASH:1}" "${HASH}0" "${HASH^^}" "${HASH:1}g"; do
    run write_checksum_file small_test_2025-12.zim "$bad"
    assert_success
  done
  run ls -A "$ZIMS"
  assert_output ''
}

###############################################################################
# detect_wget_flavor

@test "detect_wget_flavor: wget 1.x gets no extra meta4 options" {
  export FAKE_WGET_FLAVOR=wget1
  WGET_META_OPTS=(left-over)
  detect_wget_flavor
  assert_equal "${#WGET_META_OPTS[@]}" 0
}

@test "detect_wget_flavor: Wget2 gets --no-metalink" {
  export FAKE_WGET_FLAVOR=wget2
  detect_wget_flavor
  assert_equal "${#WGET_META_OPTS[@]}" 1
  assert_equal "${WGET_META_OPTS[0]}" '--no-metalink'
}

###############################################################################
# master_scrape

# scrape - run master_scrape in this shell (it fills global arrays), its output in $SANDBOX/scrape.out. Called
# from an || list so that bats' errexit does not trip over `read -d ''` returning 1 at the end of its input.
scrape() {
  master_scrape >"$SANDBOX/scrape.out" 2>&1 || fail "master_scrape returned $?: $(cat "$SANDBOX/scrape.out")"
}

assert_fixture_arrays() {
  assert_equal "$BaseURL" 'https://download.kiwix.test/zim/'
  assert_equal "${#RemoteFiles[@]}" 4
  assert_equal "${#Basenames[@]}" 4
  assert_equal "${#RemotePaths[@]}" 4
  assert_equal "${#RemoteCategory[@]}" 4
  assert_equal "${#FileSizes[@]}" 4
  assert_equal "${RemoteFiles[*]}" 'wikipedia_en_test_2026-01.zim wiktionary_fr_test_2026-02a.zim small_test_2025-12.zim big_test_2026-03.zim'
  assert_equal "${Basenames[*]}" 'wikipedia_en_test_ wiktionary_fr_test_ small_test_ big_test_'
  assert_equal "${RemotePaths[*]}" 'wikipedia/wikipedia_en_test_2026-01.zim wiktionary/wiktionary_fr_test_2026-02a.zim other/small_test_2025-12.zim other/big_test_2026-03.zim'
  assert_equal "${RemoteCategory[*]}" 'wikipedia wiktionary other other'
  assert_equal "${FileSizes[*]}" '4096 3072 1024 16384'
}

@test "master_scrape: parses the catalog into parallel arrays" {
  scrape
  assert_fixture_arrays
  run cat "$SANDBOX/scrape.out"
  assert_output --partial 'Found 4 files online'
  run cat "$FAKE_WGET_LOG"
  assert_line --index 0 --partial 'opds.library.kiwix.org'
  refute_line --index 1 --regexp '.'
  [[ -f "$INDEX_FILE" ]]
}

@test "master_scrape: a second call uses the cached index without fetching the catalog" {
  scrape
  : >"$FAKE_WGET_LOG"
  RemoteFiles=() Basenames=() RemotePaths=() RemoteCategory=() FileSizes=() BaseURL=''
  scrape
  assert_fixture_arrays
  [[ ! -s "$FAKE_WGET_LOG" ]]
}

###############################################################################
# usage_example

@test "usage_example 0: exits 0 with the usage on stdout" {
  run --separate-stderr usage_example 0
  assert_success
  assert_line --index 0 'Usage: ./kiwix-zim-updater.sh <options> /full/path/'
  assert_equal "$stderr" ''
}

@test "usage_example 2: exits 2 with the usage on stderr" {
  run --separate-stderr usage_example 2
  assert_failure 2
  assert_output ''
  [[ "$stderr" == 'Usage: ./kiwix-zim-updater.sh <options> /full/path/'* ]]
}

###############################################################################
# check_dependencies

@test "check_dependencies: passes when every tool is present" {
  SKIP_UPDATE=1
  run check_dependencies
  assert_success
  assert_output ''
}

@test "check_dependencies: a missing numfmt exits 1 and names it" {
  SKIP_UPDATE=1
  make_tooldir numfmt
  PATH="$TOOLDIR" run check_dependencies
  assert_failure 1
  assert_output --partial 'Missing required tool(s): numfmt. '
  run cat "$LOG_FILE"
  assert_output --partial 'Missing required tool(s): numfmt. Exiting...'
}

@test "N9: zim_date reads the date of a ZIM with an upper-case extension" {
  source "$SCRIPT_COPY"
  run zim_date wikipedia_en_test_2026-01.ZIM
  assert_output '2026-01'
  run zim_date wiktionary_fr_test_2026-02A.Zim
  assert_output '2026-02a'
}

@test "write_checksum_file leaves an existing file with the same hash untouched" {
  source "$SCRIPT_COPY"
  ZIMPath="$ZIMS/"
  DEBUG=0
  printf 'payload' >"$ZIMS/a_2026-01.zim"
  (cd "$ZIMS" && sha256sum a_2026-01.zim >a_2026-01.zim.sha256)
  cp "$ZIMS/a_2026-01.zim.sha256" "$SANDBOX/orig"
  write_checksum_file a_2026-01.zim "$(cut -d' ' -f1 "$SANDBOX/orig")"
  cmp "$ZIMS/a_2026-01.zim.sha256" "$SANDBOX/orig"
}
