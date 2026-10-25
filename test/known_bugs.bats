#!/usr/bin/env bats
# Known-bug tests. Each one asserts the CORRECT behaviour for a finding of
# the review (F*, H*, M*) or for a defect found while writing the harness
# (N*), and is skipped until the fix lands. The fix commit removes the skip.
#
# Count the open findings with: grep -c 'skip "[FHMN][0-9]' test/*.bats

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
}

NEW_WP=wikipedia_en_test_2026-01.zim
OLD_WP=wikipedia_en_test_2025-12.zim
WP_REMOTE=zim/wikipedia/wikipedia_en_test_2026-01.zim
OLD_WT=wiktionary_fr_test_2026-02.zim
NEW_WT=wiktionary_fr_test_2026-02a.zim
WT_REMOTE=zim/wiktionary/wiktionary_fr_test_2026-02a.zim

# Keep a pristine copy of a local ZIM to compare against after the run.
keep_copy() {
  cp "$ZIMS/$1" "$SANDBOX/$1.orig"
}

###############################################################################
# F: data safety

@test "F1: a failed download (wget exit 4) keeps the old ZIM" {
  skip "F1: wget status is never checked; the partial file passes and the old ZIM is purged"
  make_local_zim "$OLD_WP"
  keep_copy "$OLD_WP"
  export FAKE_WGET_FAIL=wikipedia_en_test_2026-01
  run_updater -d "$ZIMS"
  cmp "$ZIMS/$OLD_WP" "$SANDBOX/$OLD_WP.orig"
  run download_log
  assert_line ' !!! DOWNLOAD FAILED !!!'
}

@test "F1: a short download with wget exit 0 keeps the old ZIM (size check without -c)" {
  skip "F1: size is only verified with -c; a truncated file purges the old ZIM"
  make_local_zim "$OLD_WP"
  keep_copy "$OLD_WP"
  export FAKE_WGET_SHORT=wikipedia_en_test_2026-01
  run_updater -d "$ZIMS"
  cmp "$ZIMS/$OLD_WP" "$SANDBOX/$OLD_WP.orig"
}

@test "F1: with no meta4 and a short download, the old ZIM is kept" {
  skip "F1: no size fallback when the meta4 fetch fails; the old ZIM is purged"
  make_local_zim "$OLD_WP"
  keep_copy "$OLD_WP"
  export FAKE_WGET_META_FAIL=1 FAKE_WGET_SHORT=wikipedia_en_test_2026-01
  run_updater -d "$ZIMS"
  cmp "$ZIMS/$OLD_WP" "$SANDBOX/$OLD_WP.orig"
}

@test "F2: a failure on the first ZIM does not mark the second one failed" {
  skip "F2: DownloadFailed is never reset; the good second download is deleted as abandoned"
  make_local_zim "$OLD_WP"
  make_local_zim "$OLD_WT"
  export FAKE_WGET_CORRUPT=wikipedia_en_test_2026-01
  run_updater -d -c "$ZIMS"
  [[ -f "$ZIMS/$OLD_WP" ]]
  cmp "$ZIMS/$NEW_WT" "$(remote_file "$WT_REMOTE")"
  [[ ! -e "$ZIMS/$OLD_WT" ]]
}

@test "F3: a checksum failure leaves no 0-byte ZIM behind" {
  skip "F3: the corrupt file is rm'd and then touch'ed, leaving an empty ZIM"
  make_local_zim "$NEW_WP" --from-remote "$WP_REMOTE"
  printf 'X' | dd of="$ZIMS/$NEW_WP" bs=1 seek=10 conv=notrunc status=none
  export FAKE_WGET_CORRUPT=wikipedia_en_test_2026-01
  run_updater -f -d "$ZIMS"
  run find "$ZIMS" -type f -empty
  assert_output ''
}

@test "F4: -f in dry-run writes no .sha256 into the ZIM dir" {
  skip "F4: the verify path writes .sha256 files even in dry-run"
  make_local_zim "$NEW_WP" --from-remote "$WP_REMOTE"
  local before
  before="$(zim_dir_snapshot)"
  run_updater -f "$ZIMS"
  assert_success
  assert_equal "$(zim_dir_snapshot)" "$before"
}

@test "F4: a failed meta4 fetch does not write an empty-hash .sha256" {
  skip "F4: the .sha256 is written with an empty hash when the meta4 fetch failed"
  make_local_zim "$OLD_WP"
  export FAKE_WGET_META_FAIL=1
  run_updater -d "$ZIMS"
  if [[ -e "$ZIMS/$NEW_WP.sha256" ]]; then
    run cat "$ZIMS/$NEW_WP.sha256"
    assert_output --regexp "^[0-9a-f]{64} +$NEW_WP\$"
  fi
}

@test "F4: -f -d with a failed meta4 fetch keeps a good cached .sha256" {
  skip "F4: the verify path overwrites the cached .sha256 with an empty hash"
  make_local_zim "$NEW_WP" --from-remote "$WP_REMOTE"
  make_local_sha256 "$NEW_WP"
  cp "$ZIMS/$NEW_WP.sha256" "$SANDBOX/sha256.orig"
  export FAKE_WGET_META_FAIL=1
  run_updater -f -d "$ZIMS"
  cmp "$ZIMS/$NEW_WP.sha256" "$SANDBOX/sha256.orig"
}

@test "F5: a file named like the new ZIM in the CWD does not suppress the download" {
  skip "F5: '[[ -f \$NewZIM ]]' is resolved against the CWD instead of the ZIM dir"
  make_local_zim "$OLD_WP"
  printf 'unrelated' >"$RUN_DIR/$NEW_WP"
  run_updater -d "$ZIMS"
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
  [[ ! -e "$ZIMS/$OLD_WP" ]]
  run cat "$RUN_DIR/$NEW_WP"
  assert_output 'unrelated'
}

@test "F5: with -t, a file named like the new ZIM in the CWD does not suppress the torrent" {
  skip "F5: '[[ -f \$NewZIM ]]' is resolved against the CWD instead of the ZIM dir"
  make_local_zim "$OLD_WP"
  printf 'unrelated' >"$RUN_DIR/$NEW_WP"
  run_updater -d -t "$ZIMS"
  cmp "$ZIMS/$NEW_WP.torrent" "$(remote_file "$WP_REMOTE.torrent")"
}

@test "F6: -f verifies an unmatched local ZIM against its own .sha256 in the ZIM dir" {
  skip "F6: \$FileName is used before assignment and resolved against the CWD"
  make_local_zim orphan_test_2025-01.zim
  make_local_sha256 orphan_test_2025-01.zim
  run_updater -f "$ZIMS"
  assert_success
  assert_output --partial '- orphan_test_2025-01.zim:'
  assert_output --partial 'Cached Checksum Found'
}

###############################################################################
# H: correctness and operations

@test "H1: a nonexistent ZIM directory exits 2" {
  skip "H1: usage errors exit 0"
  run_updater "$SANDBOX/does-not-exist"
  assert_failure 2
  assert_output --partial 'is not a directory'
}

@test "H1: a missing ZIM directory argument exits 2" {
  skip "H1: usage errors exit 0"
  run_updater
  assert_failure 2
  assert_output --partial 'Kiwix ZIM Directory not provided'
}

@test "H1: an empty ZIM directory exits 1" {
  skip "H1: 'No ZIMs found' exits 0"
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'No ZIMs found'
}

@test "H1: a failed download exits 1" {
  skip "H1: a failed download exits 0"
  make_local_zim "$OLD_WP"
  export FAKE_WGET_CORRUPT=wikipedia_en_test_2026-01
  run_updater -d -c "$ZIMS"
  assert_failure 1
}

@test "H1: a catalog without remote files exits 1" {
  skip "H1: 'Could not find any remote files' exits 0"
  use_fixture_copy
  cat >"$FAKE_FIXTURES/catalog.xml" <<'EOF'
<feed>
  <updated>__NOW__</updated>
  <entry>
    <link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" href="https://download.kiwix.test/zim/rootlevel_test_2026-01.zim.meta4" length="1024" />
  </entry>
</feed>
EOF
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'Could not find any remote files'
}

@test "H1: a catalog without ZIM URLs exits 1" {
  skip "H1: 'No ZIM URLs found' exits 0"
  use_fixture_copy
  printf '<feed>\n  <updated>__NOW__</updated>\n</feed>\n' >"$FAKE_FIXTURES/catalog.xml"
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'No ZIM URLs found'
}

@test "H2: -c together with -t aborts with exit 2" {
  skip "H2: prints 'Aborting' but carries on"
  make_local_zim "$OLD_WP"
  run_updater -d -c -t "$ZIMS"
  assert_failure 2
  assert_output --partial 'Calculating Checksum not available with torrenting'
  run wget_downloads
  assert_output ''
}

@test "H3: self-update never moves download.log or kiwix-index into the script dir" {
  skip "H3: self_update cds into the script dir and never cds back"
  mkdir "$SANDBOX/bin/.git"
  export FAKE_GIT_MODE=other-branch
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'You appear to be on a different branch'
  [[ -f "$RUN_DIR/download.log" ]]
  [[ -f "$RUN_DIR/kiwix-index" ]]
  [[ ! -e "$SANDBOX/bin/download.log" ]]
  [[ ! -e "$SANDBOX/bin/kiwix-index" ]]
  run download_log
  assert_line '3. Processing ZIM(s)...'
}

@test "H4: a failed catalog fetch exits 1 and caches no kiwix-index" {
  skip "H4: the wget status is ignored and an empty index is cached"
  make_local_zim "$OLD_WP"
  export FAKE_WGET_CATALOG_FAIL=1
  run_updater "$ZIMS"
  assert_failure 1
  [[ ! -e "$RUN_DIR/kiwix-index" ]]
}

@test "H5: -n without a value exits 2" {
  skip "H5: numfmt fails silently and the size limit is dropped"
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS" -n
  assert_failure 2
}

@test "H5: -n with a garbage value exits 2" {
  skip "H5: numfmt fails silently and the size limit is dropped"
  make_local_zim "$OLD_WP"
  run_updater -n banana "$ZIMS"
  assert_failure 2
}

@test "H5: -x with a garbage value exits 2" {
  skip "H5: numfmt fails silently and the size limit is dropped"
  make_local_zim "$OLD_WP"
  run_updater -x 12parsecs "$ZIMS"
  assert_failure 2
}

@test "H5: an unknown --option exits 2 with usage" {
  skip "H5: unknown options become positionals and are ignored"
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS" --bogus
  assert_failure 2
  assert_output --partial 'Usage:'
}

@test "H5: two positional arguments exit 2" {
  skip "H5: extra positionals are silently ignored"
  mkdir "$SANDBOX/other"
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS" "$SANDBOX/other"
  assert_failure 2
}

@test "H5: an invalid -l country code warns on stderr" {
  skip "H5: the invalid -l fallback is only written to download.log"
  make_local_zim "$OLD_WP"
  run_updater --separate-stderr -l nope "$ZIMS"
  assert_success
  [[ "${stderr,,}" == *"country code"* ]]
}

@test "H6: a second instance on the same ZIM dir exits 75" {
  skip "H6: nothing prevents two runs from overlapping"
  make_local_zim "$OLD_WP"
  exec 8<"$ZIMS"
  flock -n 8
  run_updater "$ZIMS"
  exec 8<&-
  assert_failure 75
  run wget_downloads
  assert_output ''
}

@test "H7: a missing wget exits 1 with a clear message" {
  skip "H7: no dependency preflight; a missing wget looks like an empty catalog"
  local tooldir="$SANDBOX/tools" tool src
  local base_path="${PATH#"$STUB_BIN:"}"
  mkdir "$tooldir"
  for tool in bash env readlink realpath basename dirname date head tail grep \
    tee uniq wc ls numfmt du sha256sum touch rm mv cp mkdir mktemp cat sleep \
    timeout flock sed awk tr sort stat find cut id uname; do
    src="$(PATH="$base_path" command -v "$tool")" || continue
    ln -s "$src" "$tooldir/$tool"
  done
  ln -s "$STUB_BIN/git" "$tooldir/git"
  ln -s "$STUB_BIN/clear" "$tooldir/clear"
  make_local_zim "$OLD_WP"
  PATH="$tooldir" run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'wget'
  refute_output --partial 'command not found'
}

###############################################################################
# M: medium

@test "M2: clear is not called when stdout is not a terminal" {
  skip "M2: clear runs unconditionally (TERM noise under cron)"
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_success
  [[ ! -s "$FAKE_CLEAR_LOG" ]]
}

@test "M3: the array-length mismatch message is printed in red" {
  skip "M3: \${RED} is undefined, so the message has no colour"
  use_fixture_copy
  sed -i 's#</feed>#  <entry>\n    <link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" href="https://download.kiwix.test/zim/rootlevel_test_2026-01.zim.meta4" length="1024" />\n  </entry>\n</feed>#' "$FAKE_FIXTURES/catalog.xml"
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_failure
  assert_output --partial $'\033[0;31mParsed array lengths did not match'
}

###############################################################################
# N: new defects found while building the harness (not in the review table)

@test "N1: with GNU Wget2 the meta4 is read as metadata, not followed" {
  export FAKE_WGET_FLAVOR=wget2
  make_local_zim "$OLD_WP"
  run_updater -d -c "$ZIMS"
  assert_success
  assert_output --partial 'Download (mirror) : https://mirror.kiwix.test/'
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
  [[ ! -e "$ZIMS/$OLD_WP" ]]
}

@test "N2: -f -d never deletes an unmatched ZIM that has a valid own checksum" {
  skip "N2: the unmatched-ZIM verify path compares against a stale/empty ExpectedSize and rm's the ZIM"
  make_local_zim "$NEW_WP" --from-remote "$WP_REMOTE"
  make_local_zim zzz_orphan_test_2025-01.zim "$(head -c 2048 < <(yes 'orphan payload'))"
  make_local_sha256 zzz_orphan_test_2025-01.zim
  keep_copy zzz_orphan_test_2025-01.zim
  # Today the unmatched-ZIM path is only reached when "$FileName.sha256"
  # (the previous ZIM's name, see F6) exists in the CWD; provide it so this
  # test exercises the deletion with or without the F6 fix.
  cp "$(remote_file "$WP_REMOTE.sha256")" "$RUN_DIR/$NEW_WP.sha256"
  run_updater -f -d "$ZIMS"
  cmp "$ZIMS/zzz_orphan_test_2025-01.zim" "$SANDBOX/zzz_orphan_test_2025-01.zim.orig"
}

@test "N3: -f -d with a failed meta4 fetch never deletes a good ZIM" {
  skip "N3: an empty ExpectedSize fails the size check and the good ZIM is rm'd"
  make_local_zim "$NEW_WP" --from-remote "$WP_REMOTE"
  make_local_sha256 "$NEW_WP"
  export FAKE_WGET_META_FAIL=1
  run_updater -f -d "$ZIMS"
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
}

@test "N4: -S stops new .sha256 files from being written" {
  skip "N4: CHECKSUM_FILES (-S/--no-sha) is set but never read"
  make_local_zim "$OLD_WP"
  run_updater -d -S "$ZIMS"
  assert_success
  cmp "$ZIMS/$NEW_WP" "$(remote_file "$WP_REMOTE")"
  [[ ! -e "$ZIMS/$NEW_WP.sha256" ]]
}

@test "N5: -f checks an outdated ZIM against its own online checksum, not the new release's" {
  skip "N5: state 1 for an outdated ZIM uses the newer release's size/hash and rm's the intact file"
  use_fixture_copy
  make_local_zim "$OLD_WP"
  keep_copy "$OLD_WP"
  # The older release's checksum is still published next to the new one.
  (cd "$ZIMS" && sha256sum "$OLD_WP") >"$(remote_file "zim/wikipedia/$OLD_WP.sha256")"
  run_updater -f -d "$ZIMS"
  cmp "$ZIMS/$OLD_WP" "$SANDBOX/$OLD_WP.orig"
  refute_output --partial 'removing corrupt file'
}

@test "N1: with GNU Wget2 every meta4 request carries --no-metalink" {
  export FAKE_WGET_FLAVOR=wget2
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_success
  grep -qF '.meta4' "$FAKE_WGET_LOG"
  run bash -c 'grep -F .meta4 "$1" | grep -v -e --no-metalink' _ "$FAKE_WGET_LOG"
  assert_output ''
}

@test "N1: with wget 1.x no meta4 request carries --no-metalink" {
  export FAKE_WGET_FLAVOR=wget1
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_success
  grep -qF '.meta4' "$FAKE_WGET_LOG"
  run grep -e --no-metalink "$FAKE_WGET_LOG"
  assert_output ''
}
