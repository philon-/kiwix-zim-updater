#!/usr/bin/env bats
# The command line: -h, -v and the banner, the ZIM directory argument, option and value validation, and the
# exit-code contract for them: 0 = ok or nothing to update, 2 = usage error. Runtime failures (exit 1) and a
# locked ZIM directory (exit 75) are tested with the feature that fails.

setup() {
  load 'helpers/common'
  common_setup
}

###############################################################################
# Help, version and banner

@test "-h prints usage on stdout and exits 0" {
  run_updater --separate-stderr -h
  assert_success
  assert_line --index 0 'Usage: ./kiwix-zim-updater.sh <options> /full/path/'
  assert_output --partial '-d, --disable-dry-run'
  assert_equal "$stderr" ''
  run cat "$FAKE_WGET_LOG"
  assert_output ''
}

@test "the README usage block matches the -h output" {
  run bash "$SCRIPT_COPY" -h
  assert_success
  local readme
  readme="$(awk '/^## Usage$/{u=1;next} u && /^```text$/{p=1;next} p && /^```$/{exit} p' "$REPO_ROOT/README.md")"
  assert_equal "$output" "$readme"
}

@test "-v prints the version and exits 0" {
  run_updater -v
  assert_success
  assert_output "$(grep -oP '^VER="\K[^"]+' "$SCRIPT_COPY")"
  refute_output ''
}

@test "default run is a dry-run and says so" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'DRY-RUN/SIMULATION'
  assert_output --partial '- ENABLED -'
  refute_output --partial '- DISABLED -'
}

@test "-d disables the dry-run banner" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial '- DISABLED -'
  assert_output --partial '!!! Caution !!!'
}

@test "nothing to update exits 0" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  run_updater -d "$ZIMS"
  assert_success
  assert_output --partial 'Nothing to download'
}

@test "running under the legacy name kiwix-zim.sh no longer exits 2 (M5)" {
  make_local_zim "$WP_OLD"
  cp "$SCRIPT_COPY" "$SANDBOX/bin/kiwix-zim.sh"
  cd "$RUN_DIR"
  run bash "$SANDBOX/bin/kiwix-zim.sh" "$ZIMS"
  assert_success
  refute_output --partial 'deprecated'
  run download_log
  refute_output --partial 'deprecated'
}

###############################################################################
# The ZIM directory argument

@test "a nonexistent ZIM directory exits 2 with the usage on stderr, not stdout (H1)" {
  run_updater --separate-stderr "$SANDBOX/does-not-exist"
  assert_failure 2
  assert_output --partial 'is not a directory'
  refute_output --partial 'Usage:'
  [[ "$stderr" == *'Usage: ./kiwix-zim-updater.sh'* ]]
}

@test "a missing ZIM directory argument exits 2 (H1)" {
  run_updater
  assert_failure 2
  assert_output --partial 'Kiwix ZIM Directory not provided'
}

@test "a file instead of a ZIM directory exits 2" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS/$WP_OLD"
  assert_failure 2
  assert_output --partial 'is not a directory'
}

@test "two positional arguments exit 2 (H5)" {
  mkdir "$SANDBOX/other"
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS" "$SANDBOX/other"
  assert_failure 2
}

###############################################################################
# Options and their values (H2, H5)

@test "-c together with -t aborts with exit 2 (H2)" {
  make_local_zim "$WP_OLD"
  run_updater -d -c -t "$ZIMS"
  assert_failure 2
  assert_output --partial 'Calculating Checksum not available with torrenting'
  run wget_downloads
  assert_output ''
}

@test "-f together with -t aborts with exit 2, as -f implies -c (H2)" {
  make_local_zim "$WP_OLD"
  run_updater --separate-stderr -f -t "$ZIMS"
  assert_failure 2
  [[ "$stderr" == *'Calculating Checksum not available with torrenting'* ]]
  run cat "$FAKE_WGET_LOG"
  assert_output ''
}

@test "-n with a valid size (1G) is accepted (H5)" {
  make_local_zim "$WP_OLD"
  run_updater -n 1G "$ZIMS"
  assert_success
  assert_output --partial 'Update skipped (minimum'
}

@test "-x with a valid binary size (2Ki) is accepted (H5)" {
  make_local_zim big_test_2026-01.zim
  run_updater -x 2Ki "$ZIMS"
  assert_success
  # numfmt prints the locale's decimal separator.
  assert_output --regexp 'Update skipped \(maximum: 2[.,]0Ki'
}

@test "-n without a value exits 2 (H5)" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS" -n
  assert_failure 2
}

@test "-x without a value exits 2 with usage on stderr (H5)" {
  make_local_zim "$WP_OLD"
  run_updater --separate-stderr "$ZIMS" -x
  assert_failure 2
  [[ "$stderr" == *'-x requires a size'* ]]
  [[ "$stderr" == *'Usage:'* ]]
  run cat "$FAKE_WGET_LOG"
  assert_output ''
}

@test "-n followed by another option exits 2 (H5)" {
  make_local_zim "$WP_OLD"
  run_updater -n -d "$ZIMS"
  assert_failure 2
  assert_output --partial "Invalid minimum size: '-d'"
}

@test "-n with a garbage value exits 2 (H5)" {
  make_local_zim "$WP_OLD"
  run_updater -n banana "$ZIMS"
  assert_failure 2
}

@test "-x with a garbage value exits 2 (H5)" {
  make_local_zim "$WP_OLD"
  run_updater -x 12parsecs "$ZIMS"
  assert_failure 2
}

@test "a fractional byte size exits 2 (H5)" {
  make_local_zim "$WP_OLD"
  run_updater -n 1.5 "$ZIMS"
  assert_failure 2
}

@test "an unknown --option exits 2 with usage (H5)" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS" --bogus
  assert_failure 2
  assert_output --partial 'Usage:'
}

@test "an unknown short option exits 2 with usage (H5)" {
  make_local_zim "$WP_OLD"
  run_updater -z "$ZIMS"
  assert_failure 2
  assert_output --partial 'Unknown option: -z'
  assert_output --partial 'Usage:'
}

@test "-l without a value exits 2 (H5)" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS" -l
  assert_failure 2
  assert_output --partial '-l requires a country code'
}

@test "-l followed by another option exits 2 instead of eating it (H5)" {
  make_local_zim "$WP_OLD"
  run_updater -l -d "$ZIMS"
  assert_failure 2
  assert_output --partial '-l requires a country code'
}

@test "an invalid -l code still falls back and runs (H5)" {
  make_local_zim "$WP_OLD"
  run_updater --separate-stderr -l se "$ZIMS"
  assert_success
  [[ "$stderr" == *"Invalid country code 'se'"* ]]
  run grep -c 'meta4?country=$' "$FAKE_WGET_LOG"
  assert_output '1'
}
