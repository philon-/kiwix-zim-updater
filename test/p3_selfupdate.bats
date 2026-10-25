#!/usr/bin/env bats
# H8: self-update is opt-in (-U) and never touches a clone it should not.

bats_require_minimum_version 1.5.0

setup() {
  load 'helpers/common'
  common_setup
}

OLD_WP=wikipedia_en_test_2025-12.zim

###############################################################################
# Opt-in

@test "H8: a default run makes no git call, even next to a .git" {
  mkdir "$SANDBOX/bin/.git"
  export FAKE_GIT_MODE=current
  make_local_zim "$OLD_WP"
  run_updater "$ZIMS"
  assert_success
  assert_output --partial '1. Checking for Script Updates...'
  assert_output --partial 'Check Skipped (use -U to enable)'
  run cat "$FAKE_GIT_LOG"
  assert_output ''
}

@test "H8: -u and --skip-update are still accepted and run no git" {
  mkdir "$SANDBOX/bin/.git"
  make_local_zim "$OLD_WP"
  run_updater -u "$ZIMS"
  assert_success
  run_updater --skip-update "$ZIMS"
  assert_success
  run cat "$FAKE_GIT_LOG"
  assert_output ''
}

@test "H8: the usage documents -U and the -u compatibility no-op" {
  run_updater -h
  assert_success
  assert_line '    -U, --self-update          Updates this script from its git clone before running (off by default).'
  assert_line '    -u, --skip-update          Accepted for compatibility; self-update is now off unless -U is given.'
}

@test "H8: -U outside a git clone skips the update with a message" {
  make_local_zim "$OLD_WP"
  run_updater -U "$ZIMS"
  assert_success
  assert_output --partial 'Git Clone Not Detected: Skipping Update Check'
  run cat "$FAKE_GIT_LOG"
  assert_output ''
}

@test "H8: --self-update on another branch skips the update" {
  mkdir "$SANDBOX/bin/.git"
  export FAKE_GIT_MODE=other-branch
  make_local_zim "$OLD_WP"
  run_updater --self-update "$ZIMS"
  assert_success
  assert_output --partial 'You appear to be on a different branch'
  run cat "$FAKE_GIT_LOG"
  assert_output --partial 'rev-parse --abbrev-ref HEAD'
  refute_output --partial 'fetch'
  refute_output --partial 'pull'
}

###############################################################################
# The update path, against a real local origin

# Set up $SANDBOX/origin.git (bare) and $SANDBOX/clone, a clone of it on main
# whose only commit holds the script and a NOTES file. Git in the run is the
# real one behind a wrapper that logs every call to $FAKE_GIT_LOG. Git is kept
# inside the sandbox (AGENTS.md, hard rule 1), see isolate_git.
setup_clone() {
  REAL_GIT="$(PATH="${PATH#"$STUB_BIN:"}" command -v git)" || skip "git is not installed"
  isolate_git
  mkdir "$SANDBOX/realgit"
  cat >"$SANDBOX/realgit/git" <<WRAPPER
#!$(command -v bash)
printf '%s\n' "\$*" >>"\$FAKE_GIT_LOG"
exec "$REAL_GIT" "\$@"
WRAPPER
  chmod +x "$SANDBOX/realgit/git"
  sgit init -q --bare "$SANDBOX/origin.git"
  sgit clone -q "$SANDBOX/origin.git" "$SANDBOX/clone" 2>/dev/null
  sgit -C "$SANDBOX/clone" checkout -q -B main
  cp "$REPO_ROOT/kiwix-zim-updater.sh" "$SANDBOX/clone/"
  chmod +x "$SANDBOX/clone/kiwix-zim-updater.sh"
  echo 'tracked notes' >"$SANDBOX/clone/NOTES"
  sgit -C "$SANDBOX/clone" add -A
  sgit -C "$SANDBOX/clone" commit -q -m 'v1'
  sgit -C "$SANDBOX/clone" push -q origin main
  CLONE_SCRIPT="$SANDBOX/clone/kiwix-zim-updater.sh"
}

# isolate_git - Keep every git call of the test, and of the script under test, inside the sandbox:
# - drop inherited repository selectors and injected config (GIT_DIR, GIT_WORK_TREE, GIT_CONFIG_PARAMETERS, ...;
#   the list git itself considers repository-local, plus GIT_CONFIG_KEY_n/VALUE_n), which could otherwise redirect
#   `add`, `commit` or `push` to a real repository despite `-C`;
# - give git a home, an XDG config directory and an empty global config inside the sandbox, so neither the user's
#   config nor their ignore and attributes files apply, and no system config;
# - stop repository discovery at the sandbox.
isolate_git() {
  local var
  while read -r var; do
    unset "$var"
  done < <("$REAL_GIT" rev-parse --local-env-vars)
  for var in "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}"; do
    unset "$var"
  done
  unset GIT_CONFIG_COUNT GIT_TEMPLATE_DIR GIT_SSH_COMMAND GIT_ASKPASS
  mkdir -p "$SANDBOX/home/.config"
  : >"$SANDBOX/home/.gitconfig"
  export HOME="$SANDBOX/home" XDG_CONFIG_HOME="$SANDBOX/home/.config" GIT_CONFIG_GLOBAL="$SANDBOX/home/.gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$SANDBOX"
}

# git for the test's own setup: real git, with an identity and no signing for
# the sandbox repositories only.
sgit() {
  "$REAL_GIT" -c user.name='Test' -c user.email='test@example.invalid' \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

# Publish a new script version (VER=9.9-test) to origin from another clone.
push_update() {
  sgit clone -q "$SANDBOX/origin.git" "$SANDBOX/dev"
  sed -i 's/^VER=.*/VER="9.9-test"/' "$SANDBOX/dev/kiwix-zim-updater.sh"
  sgit -C "$SANDBOX/dev" commit -q -am 'v2'
  sgit -C "$SANDBOX/dev" push -q origin main
}

# run_clone <args...> - run the clone's script from $RUN_DIR with the real git.
run_clone() {
  cd "$RUN_DIR" || return 1
  PATH="$SANDBOX/realgit:$PATH" run bash "$CLONE_SCRIPT" "$@"
}

head_of() {
  sgit -C "$1" rev-parse "${2:-HEAD}"
}

@test "H8: -U with an update available fast-forwards, re-execs once and completes" {
  setup_clone
  push_update
  make_local_zim "$OLD_WP"
  run_clone -U "$ZIMS"
  assert_success
  assert_output --partial 'Version: Mismatched'
  assert_output --partial 'Running the updated version'
  assert_output --partial 'v9.9-test'
  assert_equal "$(grep -c 'Update Complete' <<<"$output")" 1
  assert_equal "$(grep -c '3. Processing ZIM(s)...' <<<"$output")" 1
  assert_equal "$(head_of "$SANDBOX/clone")" "$(head_of "$SANDBOX/origin.git" main)"
  grep -q '^VER="9.9-test"$' "$CLONE_SCRIPT"
  assert_equal "$(grep -c 'pull' "$FAKE_GIT_LOG")" 1
  assert_equal "$(grep -c 'fetch' "$FAKE_GIT_LOG")" 1
  run grep 'stash' "$FAKE_GIT_LOG"
  assert_output ''
  run download_log
  assert_line '3. Processing ZIM(s)...'
}

@test "H8: -U when up to date reports Version: Current and pulls nothing" {
  setup_clone
  make_local_zim "$OLD_WP"
  run_clone -U "$ZIMS"
  assert_success
  assert_output --partial 'Version: Current'
  refute_output --partial 'Update Complete'
  run grep -E 'pull|stash' "$FAKE_GIT_LOG"
  assert_output ''
}

@test "H8: -U with local changes refuses to update and never stashes" {
  setup_clone
  push_update
  echo 'my local edit' >>"$SANDBOX/clone/NOTES"
  local before
  before="$(head_of "$SANDBOX/clone")"
  make_local_zim "$OLD_WP"
  run_clone -U "$ZIMS"
  assert_success
  assert_output --partial 'has local changes: Not updating'
  refute_output --partial 'Update Complete'
  refute_output --partial 'v9.9-test'
  assert_output --partial '3. Processing ZIM(s)...'
  assert_equal "$(head_of "$SANDBOX/clone")" "$before"
  run tail -n 1 "$SANDBOX/clone/NOTES"
  assert_output 'my local edit'
  run sgit -C "$SANDBOX/clone" stash list
  assert_output ''
  run grep -E 'pull|stash|checkout|reset' "$FAKE_GIT_LOG"
  assert_output ''
}

@test "H8: -U with an untracked file in the clone refuses to update" {
  setup_clone
  push_update
  echo 'scratch' >"$SANDBOX/clone/untracked.txt"
  make_local_zim "$OLD_WP"
  run_clone -U "$ZIMS"
  assert_success
  assert_output --partial 'has local changes: Not updating'
  [[ -f "$SANDBOX/clone/untracked.txt" ]]
  run grep -E 'pull|stash' "$FAKE_GIT_LOG"
  assert_output ''
}

@test "H8: -U with a failing fetch reports it and continues with the current version" {
  setup_clone
  push_update
  sgit -C "$SANDBOX/clone" remote set-url origin "$SANDBOX/missing.git"
  make_local_zim "$OLD_WP"
  run_clone -U "$ZIMS"
  assert_success
  assert_output --partial 'Could not fetch updates'
  refute_output --partial 'Version: Current'
  refute_output --partial 'Version: Mismatched'
  assert_output --partial '3. Processing ZIM(s)...'
  run grep -E 'diff|pull|stash' "$FAKE_GIT_LOG"
  assert_output ''
  run download_log
  assert_output --partial 'Could not fetch updates'
}

@test "H8: -U with diverged local commits reports the failed fast-forward and continues" {
  setup_clone
  push_update
  echo 'local commit' >>"$SANDBOX/clone/NOTES"
  sgit -C "$SANDBOX/clone" commit -q -am 'local'
  local before
  before="$(head_of "$SANDBOX/clone")"
  make_local_zim "$OLD_WP"
  run_clone -U "$ZIMS"
  assert_success
  assert_output --partial 'Update failed'
  refute_output --partial 'Update Complete'
  assert_output --partial '3. Processing ZIM(s)...'
  assert_equal "$(head_of "$SANDBOX/clone")" "$before"
}

@test "H8: without -U a clone with an update available makes no git call" {
  setup_clone
  push_update
  make_local_zim "$OLD_WP"
  run_clone "$ZIMS"
  assert_success
  assert_output --partial 'Check Skipped (use -U to enable)'
  run cat "$FAKE_GIT_LOG"
  assert_output ''
}

@test "R8: -U re-execs correctly when started as 'bash kiwix-zim-updater.sh' from inside the clone" {
  setup_clone
  # download.log and kiwix-index land in the clone (the CWD); ignore them like the real repository does
  cp "$REPO_ROOT/.gitignore" "$SANDBOX/clone/.gitignore"
  sgit -C "$SANDBOX/clone" add .gitignore
  sgit -C "$SANDBOX/clone" commit -q -m 'ignore run files'
  sgit -C "$SANDBOX/clone" push -q origin main
  push_update
  chmod a-x "$CLONE_SCRIPT"
  sgit -C "$SANDBOX/clone" config core.fileMode false
  make_local_zim "$OLD_WP"
  cd "$SANDBOX/clone" || return 1
  PATH="$SANDBOX/realgit:$PATH" run bash kiwix-zim-updater.sh -U "$ZIMS"
  assert_success
  assert_output --partial 'Running the updated version'
  assert_output --partial 'v9.9-test'
}

@test "isolation: inherited git variables and user files cannot leak into the sandbox repositories" {
  local real_git
  real_git="$(PATH="${PATH#"$STUB_BIN:"}" command -v git)" || skip "git is not installed"
  # A decoy repository and user-level git files, as an unlucky caller's environment could point at them
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" init -q --bare "$SANDBOX/decoy.git"
  mkdir -p "$SANDBOX/decoy-wt" "$SANDBOX/outer-xdg/git"
  echo '*' >"$SANDBOX/outer-xdg/git/ignore"
  export GIT_DIR="$SANDBOX/decoy.git" GIT_WORK_TREE="$SANDBOX/decoy-wt" XDG_CONFIG_HOME="$SANDBOX/outer-xdg"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0="$SANDBOX/outer-xdg/git/ignore"
  setup_clone
  push_update
  # An untracked file must still be seen (the leaked ignore-everything rules would hide it) ...
  echo 'scratch' >"$SANDBOX/clone/untracked.txt"
  make_local_zim "$OLD_WP"
  run_clone -U "$ZIMS"
  assert_output --partial 'local changes'
  # ... and nothing reached the decoy repository
  run env -i PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$real_git" --git-dir="$SANDBOX/decoy.git" for-each-ref
  assert_output ''
  [[ -z "$(find "$SANDBOX/decoy.git/objects" -type f)" ]]
}
