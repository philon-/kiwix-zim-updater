#!/usr/bin/env bats
# Self-tests for the harness: the wget/git/df/kiwix-manage stubs and the fixtures.

setup() {
  load 'helpers/common'
  common_setup
}

@test "stubs: wget serves the catalog for opds URLs, with __NOW__ substituted" {
  run wget --show-progress -q -O - 'https://opds.library.kiwix.org/catalog/v2/entries?count=-1'
  assert_success
  assert_output --partial 'type="application/x-zim"'
  refute_output --partial '__NOW__'
  assert_output --regexp '<updated>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z</updated>'
}

@test "stubs: wget maps download and mirror hosts to the same remote tree" {
  run wget -q -O - 'https://download.kiwix.test/zim/other/small_test_2025-12.zim.meta4?country='
  assert_success
  assert_output --partial '<size>1024</size>'
  wget -q -c -O "$SANDBOX/a" 'https://mirror.kiwix.test/zim/other/small_test_2025-12.zim'
  wget -q -c -O "$SANDBOX/b" 'https://download.kiwix.test/zim/other/small_test_2025-12.zim'
  cmp "$SANDBOX/a" "$(remote_file zim/other/small_test_2025-12.zim)"
  cmp "$SANDBOX/b" "$SANDBOX/a"
}

@test "stubs: wget missing fixture exits 8 and still truncates the -O file" {
  printf 'stale' >"$SANDBOX/out"
  run wget -q -O "$SANDBOX/out" 'https://mirror.kiwix.test/zim/nope/nope_2026-01.zim'
  assert_failure 8
  assert_exists "$SANDBOX/out"
  refute_nonempty "$SANDBOX/out"
}

@test "stubs: wget --spider reports existence via exit status only" {
  run wget -S --spider -q -O - 'https://download.kiwix.test/zim/other/small_test_2025-12.zim.sha256'
  assert_success
  assert_output ''
  run wget -S --spider -q -O - 'https://download.kiwix.test/zim/other/missing.sha256'
  assert_failure 8
}

@test "stubs: wget failure knobs" {
  local src
  src="$(remote_file zim/other/big_test_2026-03.zim)"

  FAKE_WGET_FAIL=big_test run wget -q -c -O "$SANDBOX/f" 'https://mirror.kiwix.test/zim/other/big_test_2026-03.zim'
  assert_failure 4
  [[ $(stat -c %s "$SANDBOX/f") -eq 8192 ]]

  FAKE_WGET_SHORT=big_test run wget -q -c -O "$SANDBOX/s" 'https://mirror.kiwix.test/zim/other/big_test_2026-03.zim'
  assert_success
  [[ $(stat -c %s "$SANDBOX/s") -eq 8192 ]]

  FAKE_WGET_CORRUPT=big_test run wget -q -c -O "$SANDBOX/c" 'https://mirror.kiwix.test/zim/other/big_test_2026-03.zim'
  assert_success
  [[ $(stat -c %s "$SANDBOX/c") -eq $(stat -c %s "$src") ]]
  run cmp -s "$SANDBOX/c" "$src"
  assert_failure

  # NETFAIL: fails without creating or touching the -O file
  printf 'keep' >"$SANDBOX/n"
  FAKE_WGET_NETFAIL=big_test run wget -q -c -O "$SANDBOX/n" 'https://mirror.kiwix.test/zim/other/big_test_2026-03.zim'
  assert_failure 4
  run cat "$SANDBOX/n"
  assert_output 'keep'
  FAKE_WGET_NETFAIL=big_test run wget -q -O "$SANDBOX/n2" 'https://mirror.kiwix.test/zim/other/big_test_2026-03.zim'
  assert_failure 4
  refute_exists "$SANDBOX/n2"

  FAKE_WGET_META_FAIL=1 run wget -q -O - 'https://download.kiwix.test/zim/other/big_test_2026-03.zim.meta4?country='
  assert_failure 8
  assert_output ''

  FAKE_WGET_CATALOG_FAIL=1 run wget --show-progress -q -O - 'https://opds.library.kiwix.org/catalog/v2/entries?count=-1'
  assert_failure 4
  assert_output ''
}

@test "stubs: wget -c resumes a partial file" {
  local src
  src="$(remote_file zim/other/big_test_2026-03.zim)"
  head -c 100 "$src" >"$SANDBOX/r"
  wget -q -c -O "$SANDBOX/r" 'https://mirror.kiwix.test/zim/other/big_test_2026-03.zim'
  cmp "$SANDBOX/r" "$src"
}

@test "stubs: wget2 flavour follows metalinks unless --no-metalink" {
  export FAKE_WGET_FLAVOR=wget2
  run wget -q -O - 'https://download.kiwix.test/zim/other/small_test_2025-12.zim.meta4'
  assert_success
  refute_output --partial '<metalink'
  run wget -q --no-metalink -O - 'https://download.kiwix.test/zim/other/small_test_2025-12.zim.meta4'
  assert_output --partial '<metalink'
  unset FAKE_WGET_FLAVOR
  run wget -q --no-metalink -O - 'https://download.kiwix.test/zim/other/small_test_2025-12.zim.meta4'
  assert_failure 2
}

@test "stubs: wget rejects unknown options and logs every call" {
  run wget --bogus -O - 'https://download.kiwix.test/zim/x'
  assert_failure 2
  run grep -c . "$FAKE_WGET_LOG"
  assert_output '1'
}

@test "stubs: git fails loudly by default and fakes a dev branch on request" {
  run git status
  assert_failure 97
  FAKE_GIT_MODE=other-branch run git rev-parse --abbrev-ref HEAD
  assert_success
  assert_output 'dev'
  run cat "$FAKE_GIT_LOG"
  assert_line 'status'
}

@test "stubs: fixtures agree with each other (length, size, sha256)" {
  local meta4 file size sha length
  for meta4 in "$FAKE_FIXTURES"/remote/zim/*/*.zim.meta4; do
    file="${meta4%.meta4}"
    size=$(stat -c %s "$file")
    # Like the real catalog: length is the size rounded up to whole KiB.
    length=$(( (size + 1023) / 1024 * 1024 ))
    sha=$(sha256sum "$file" | cut -d' ' -f1)
    grep -q "<size>$size</size>" "$meta4"
    grep -q "<hash type=\"sha-256\">$sha</hash>" "$meta4"
    grep -q "^$sha  $(basename "$file")\$" "$file.sha256"
    grep -q "href=\"https://download.kiwix.test/zim/${file#*/remote/zim/}.meta4\" length=\"$length\"" "$FAKE_FIXTURES/catalog.xml"
  done
}

@test "stubs: fixtures/build.sh output is committed and up to date" {
  cp -r "$FIXTURES_SRC" "$SANDBOX/rebuilt"
  "$SANDBOX/rebuilt/build.sh"
  run diff -r "$FIXTURES_SRC" "$SANDBOX/rebuilt"
  assert_success
}
