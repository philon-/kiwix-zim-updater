#!/usr/bin/env bats
# The dependency check before any work: every missing tool is named, and git and kiwix-manage are only required
# when -U or --library needs them (H7).

setup() {
  load 'helpers/common'
  common_setup
}

@test "missing tools, wget among them, are all named on stderr before any network access (H7)" {
  make_tooldir wget numfmt flock
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater --separate-stderr "$ZIMS"
  assert_failure 1
  [[ "$stderr" == *"wget"* ]]
  [[ "$stderr" == *"numfmt"* ]]
  [[ "$stderr" == *"flock"* ]]
  [[ "$stderr" != *"command not found"* ]]
  refute_output --partial 'command not found'
  refute_output --partial 'Building online ZIM list'
}

@test "a grep without -P support is reported (H7)" {
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
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater "$ZIMS"
  assert_failure 1
  assert_output --partial 'grep -P'
}

@test "git is required when the self-update would run (H7)" {
  make_tooldir git
  mkdir "$SANDBOX/bin/.git"
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater -U "$ZIMS"
  assert_failure 1
  assert_output --partial 'git'
}

@test "git is not required without -U, even in a git clone (H7)" {
  make_tooldir git
  mkdir "$SANDBOX/bin/.git"
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater "$ZIMS"
  assert_success
  refute_output --partial 'Missing required tool'
}

@test "git is not required outside a git clone (H7)" {
  make_tooldir git
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater -U "$ZIMS"
  assert_success
  refute_output --partial 'Missing required tool'
}

@test "kiwix-manage is only required with --library" {
  make_tooldir kiwix-manage
  make_local_zim "$WP_OLD"
  PATH="$TOOLDIR" run_updater "$ZIMS"
  assert_success
  PATH="$TOOLDIR" run_updater --library "$ZIMS/library.xml" "$ZIMS"
  assert_failure 1
  assert_output --partial 'kiwix-manage'
}
