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
