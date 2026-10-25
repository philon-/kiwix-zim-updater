#!/usr/bin/env bats
# Unattended safety: free space (--min-free), network and metadata outages, a read-only ZIM directory, one instance
# per ZIM directory (H6) and globals that must not leak in from the environment (M4).

setup() {
  load 'helpers/common'
  common_setup
}

teardown() {
  # The read-only tests remove write permission; give it back so bats can clean up the sandbox even when one fails.
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
}

GiB=1073741824

###############################################################################
# Free space

@test "free space: a download that would leave less than --min-free (default 1Gi) is skipped, old ZIM kept" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  export FAKE_DF_AVAIL=$((GiB + 4095))
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'Download skipped, not enough free space'
  assert_output --partial 'must stay free (--min-free)'
  assert_zim_unchanged "$WP_OLD"
  refute_exists "$ZIMS/$WP_NEW"
  refute_exists "$ZIMS/$WP_NEW.part"
  run wget_downloads
  assert_output ''
}

@test "free space: exactly enough room for the download plus the reserve is fine" {
  make_local_zim "$WP_OLD"
  export FAKE_DF_AVAIL=$((GiB + 4096))
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
}

@test "free space: only the bytes still missing from a .part count" {
  make_local_zim "$WP_OLD"
  head -c 4000 "$(remote_file "$WP_REMOTE")" >"$ZIMS/$WP_NEW.part"
  export FAKE_DF_AVAIL=$((GiB + 96))
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
}

@test "free space: --min-free sets the reserve, 0 disables it" {
  make_local_zim "$WP_OLD"
  export FAKE_DF_AVAIL=5000
  run_updater -d --min-free 0 "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
}

@test "free space: --min-free 2Gi is honoured" {
  make_local_zim "$WP_OLD"
  export FAKE_DF_AVAIL=$((GiB + GiB / 2))
  run_updater -d --min-free 2Gi "$ZIMS"
  assert_failure 1
  assert_output --partial '2.0Gi must stay free'
  refute_exists "$ZIMS/$WP_NEW.part"
}

@test "free space: an invalid --min-free is a usage error" {
  make_local_zim "$WP_OLD"
  run_updater -d --min-free lots "$ZIMS"
  assert_failure 2
  run_updater -d "$ZIMS" --min-free
  assert_failure 2
}

@test "free space: a dry-run only warns" {
  make_local_zim "$WP_OLD"
  export FAKE_DF_AVAIL=100
  local before
  before="$(zim_dir_snapshot)"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '*** Simulated *** The download would be skipped: not enough free space'
  assert_equal "$(zim_dir_snapshot)" "$before"
}

###############################################################################
# Outages

@test "metadata outage: nothing is downloaded when the size cannot be verified, old ZIM kept (F1, F4)" {
  make_local_zim "$WP_OLD"
  keep_copy "$WP_OLD"
  # A download would come back short; it must not even be started
  export FAKE_WGET_META_FAIL=1 FAKE_WGET_SHORT="$WP_NEW"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_output --partial 'Download skipped, metadata unavailable'
  run wget_downloads
  assert_output ''
  assert_zim_unchanged "$WP_OLD"
  refute_exists "$ZIMS/$WP_NEW.part"
  # Without metadata the download cannot be verified, so no checksum may be written at all
  refute_exists "$ZIMS/$WP_NEW.sha256"
}

@test "internet outage: a -d run fails with exit 1 and leaves the ZIM directory byte-for-byte unchanged" {
  make_local_zim "$WP_OLD"
  make_local_sha256 "$WP_OLD"
  printf 'interrupted' >"$ZIMS/$WP_NEW.part"
  run_updater -d "$ZIMS"
  assert_success
  local before
  before="$(cd "$ZIMS" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)"
  export FAKE_WGET_CATALOG_FAIL=1 FAKE_WGET_META_FAIL=1 FAKE_WGET_NETFAIL=kiwix.test
  run_updater -d -g "$ZIMS"
  assert_failure 1
  assert_equal "$(cd "$ZIMS" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)" "$before"
  assert_nonempty "$RUN_DIR/kiwix-index"
}

@test "internet outage: -f -d -c --clean-partials changes nothing either" {
  make_local_zim "$WP_NEW" --from-remote "$WP_REMOTE"
  make_local_sha256 "$WP_NEW"
  make_local_zim "$WP_OLD"
  printf 'partial' >"$ZIMS/wikipedia_en_test_2025-06.zim.part"
  local before
  before="$(cd "$ZIMS" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)"
  export FAKE_WGET_CATALOG_FAIL=1 FAKE_WGET_META_FAIL=1 FAKE_WGET_NETFAIL=kiwix.test
  run_updater -f -d -c --clean-partials -g "$ZIMS"
  assert_failure 1
  assert_equal "$(cd "$ZIMS" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)" "$before"
}

###############################################################################
# A read-only ZIM directory forces dry-run; with -d that is a failure cron must see (N8)

@test "-d on a read-only ZIM dir changes nothing and exits 1 (N8)" {
  [[ $(id -u) -ne 0 ]] || skip "root ignores directory permissions"
  make_local_zim "$WP_OLD"
  chmod a-w "$ZIMS"
  local before
  before="$(zim_dir_snapshot)"
  run_updater -d "$ZIMS"
  assert_failure 1
  assert_output --partial "Cannot write to '$ZIMS'"
  assert_output --partial 'the ZIM directory is not writable, so nothing was changed'
  assert_equal "$(zim_dir_snapshot)" "$before"
}

@test "a plain dry-run on a read-only ZIM dir works and exits 0 (H6, N8)" {
  [[ $(id -u) -ne 0 ]] || skip "root ignores directory permissions"
  make_local_zim "$WP_OLD"
  chmod a-w "$ZIMS"
  local before
  before="$(zim_dir_snapshot)"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'Building online ZIM list'
  refute_output --partial 'nothing was changed'
  assert_equal "$(zim_dir_snapshot)" "$before"
}

@test "the lock is also taken on a read-only ZIM dir (H6)" {
  [[ $(id -u) -ne 0 ]] || skip "root ignores directory permissions"
  make_local_zim "$WP_OLD"
  chmod a-w "$ZIMS"
  exec 8<"$ZIMS"
  flock -n 8
  run_updater -d "$ZIMS"
  exec 8<&-
  assert_failure 75
}

###############################################################################
# One instance per ZIM directory (H6)

@test "a second instance on the same ZIM dir exits 75, says so on stderr and changes nothing (H6)" {
  make_local_zim "$WP_OLD"
  local before
  before="$(zim_dir_snapshot)"
  exec 8<"$ZIMS"
  flock -n 8
  run_updater --separate-stderr -d "$ZIMS"
  exec 8<&-
  assert_failure 75
  [[ "$stderr" == *"already running"* ]]
  refute_output --partial 'Building online ZIM list'
  assert_equal "$(zim_dir_snapshot)" "$before"
  run grep -F opds "$FAKE_WGET_LOG"
  assert_failure
  run wget_downloads
  assert_output ''
}

@test "a lock on another ZIM dir does not block this one (H6)" {
  mkdir "$SANDBOX/other"
  make_local_zim "$WP_OLD"
  exec 8<"$SANDBOX/other"
  flock -n 8
  run_updater "$ZIMS"
  exec 8<&-
  assert_success
}

@test "the lock is released when a run ends, so the next run works (H6)" {
  make_local_zim "$WP_OLD"
  run_updater "$ZIMS"
  assert_success
  run_updater "$ZIMS"
  assert_success
  # and nothing else holds it afterwards
  exec 8<"$ZIMS"
  flock -n 8
  exec 8<&-
}

###############################################################################
# Every global is initialised, so nothing leaks in from the environment (M4). common_setup unsets these variables;
# the tests export them deliberately.

@test "SKIP_PURGE=1 in the environment does not stop -d from purging (M4)" {
  make_local_zim "$WP_OLD"
  export SKIP_PURGE=1
  run_updater -d "$ZIMS"
  assert_success
  cmp "$ZIMS/$WP_NEW" "$(remote_file "$WP_REMOTE")"
  refute_exists "$ZIMS/$WP_OLD"
}

@test "SKIP_PURGE in the environment is never evaluated as arithmetic (M4)" {
  make_local_zim "$WP_OLD"
  export SKIP_PURGE="x[\$(touch '$SANDBOX/pwned')]"
  run_updater -d "$ZIMS"
  assert_success
  refute_exists "$SANDBOX/pwned"
}

@test "COUNTRY_CODE in the environment does not reach the meta4 request (M4)" {
  make_local_zim "$WP_OLD"
  export COUNTRY_CODE=XX
  run_updater "$ZIMS"
  assert_success
  run grep -c 'meta4?country=$' "$FAKE_WGET_LOG"
  assert_output '1'
  run grep -F 'country=XX' "$FAKE_WGET_LOG"
  assert_output ''
}

@test "POSITIONAL_ARGS in the environment does not replace the ZIM directory (M4)" {
  make_local_zim "$WP_OLD"
  export POSITIONAL_ARGS="$SANDBOX/elsewhere"
  run_updater "$ZIMS"
  assert_success
  refute_output --partial 'is not a directory'
  assert_output --partial "- $WP_OLD:"
}
