#!/usr/bin/env bats
# Operational safeguards: dependency preflight (H7), the cached catalog
# index (H4) and the lock on the ZIM directory (H6).

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
}

OLD_WP=wikipedia_en_test_2025-12.zim

# make_tooldir [<tool to leave out>...]
# Build $SANDBOX/tools with symlinks to the real tools the script needs, plus
# the wget, git and clear stubs, and leave out the named tools.
make_tooldir() {
  local tooldir="$SANDBOX/tools" tool src skip
  local base_path="${PATH#"$STUB_BIN:"}"
  mkdir -p "$tooldir"
  for tool in bash env readlink realpath basename dirname date head tail grep \
    tee uniq wc ls numfmt du sha256sum touch rm mv cp mkdir mktemp cat sleep \
    timeout flock sed awk tr sort stat find cut id uname; do
    for skip in "$@"; do
      [[ "$tool" == "$skip" ]] && continue 2
    done
    src="$(PATH="$base_path" command -v "$tool")" || continue
    ln -s "$src" "$tooldir/$tool"
  done
  for tool in wget git clear; do
    for skip in "$@"; do
      [[ "$tool" == "$skip" ]] && continue 2
    done
    ln -s "$STUB_BIN/$tool" "$tooldir/$tool"
  done
  TOOLDIR="$tooldir"
}

###############################################################################
# H7: dependency preflight

@test "H7: several missing tools are all named on stderr, before any network access" {
  make_tooldir wget numfmt flock
  make_local_zim "$OLD_WP"
  PATH="$TOOLDIR" run_updater --separate-stderr "$ZIMS"
  assert_failure 1
  [[ "$stderr" == *"wget"* ]]
  [[ "$stderr" == *"numfmt"* ]]
  [[ "$stderr" == *"flock"* ]]
  refute_output --partial 'Building online ZIM list'
}

@test "H7: a grep without -P support is reported" {
  make_tooldir grep
  local real_grep
  real_grep="$(command -v grep)"
  # A grep that refuses -P, like BusyBox or BSD grep.
  cat >"$TOOLDIR/grep" <<EOF
#!$(command -v bash)
for a in "\$@"; do
  [[ "\$a" == -*P* ]] && { echo "grep: invalid option -- 'P'" >&2; exit 2; }
done
exec "$real_grep" "\$@"
EOF
  chmod +x "$TOOLDIR/grep"
  make_local_zim "$OLD_WP"
  PATH="$TOOLDIR" run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'grep -P'
}

@test "H7: git is required when the self-update would run" {
  make_tooldir git
  mkdir "$SANDBOX/bin/.git"
  make_local_zim "$OLD_WP"
  PATH="$TOOLDIR" run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'git'
}

@test "H7: git is not required with -u" {
  make_tooldir git
  mkdir "$SANDBOX/bin/.git"
  make_local_zim "$OLD_WP"
  PATH="$TOOLDIR" run_updater -u "$ZIMS"
  assert_success
  refute_output --partial 'Missing required tool'
}

@test "H7: git is not required outside a git clone" {
  make_tooldir git
  make_local_zim "$OLD_WP"
  PATH="$TOOLDIR" run_updater "$ZIMS"
  assert_success
  refute_output --partial 'Missing required tool'
}

###############################################################################
# H6: one instance per ZIM directory

teardown() {
  # The read-only test removes write permission; give it back so bats can
  # clean up the sandbox even when that test fails.
  chmod -R u+w "$SANDBOX" 2>/dev/null || true
}

@test "H6: a held lock is reported on stderr and creates nothing in the ZIM dir" {
  make_local_zim "$OLD_WP"
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
}

@test "H6: a lock on another ZIM dir does not block this one" {
  mkdir "$SANDBOX/other"
  make_local_zim "$OLD_WP"
  exec 8<"$SANDBOX/other"
  flock -n 8
  run_updater "$ZIMS"
  exec 8<&-
  assert_success
}

@test "H6: the lock is released when a run ends, so the next run works" {
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_success
  run_updater "$ZIMS"
  assert_success
  # and nothing else holds it afterwards
  exec 8<"$ZIMS"
  flock -n 8
  exec 8<&-
}

@test "H6: a dry run on a read-only ZIM dir still works with the lock" {
  [[ $(id -u) -ne 0 ]] || skip "root ignores directory permissions"
  make_local_zim "$OLD_WP"
  chmod a-w "$ZIMS"
  local before
  before="$(zim_dir_snapshot)"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial 'Building online ZIM list'
  assert_equal "$(zim_dir_snapshot)" "$before"
}

@test "H6: the lock is also taken on a read-only ZIM dir" {
  [[ $(id -u) -ne 0 ]] || skip "root ignores directory permissions"
  make_local_zim "$OLD_WP"
  chmod a-w "$ZIMS"
  exec 8<"$ZIMS"
  flock -n 8
  run_updater -d "$ZIMS"
  exec 8<&-
  assert_failure 75
}
