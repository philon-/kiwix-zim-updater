#!/usr/bin/env bats
# docker/docker-entrypoint.sh and docker/healthcheck.sh, without Docker: the entrypoint runs a stub updater
# (KIWIX_ZIM_UPDATER) that records its arguments and exits with $STUB_EXIT.

bats_require_minimum_version 1.5.0

ENTRYPOINT_ENV_VARS=(ZIM_DIR STATE_DIR DRY_RUN CHECKSUM VERIFY_LIBRARY SKIP_PURGE NO_SHA CLEAN_PARTIALS MIN_SIZE MAX_SIZE
  MIN_FREE_SPACE COUNTRY LIBRARY_XML DOWNLOAD_METHOD FORCE_FETCH_INDEX RUN_INTERVAL EXTRA_ARGS KIWIX_ZIM_UPDATER)

setup() {
  load 'helpers/common'
  common_setup

  ENTRYPOINT="$REPO_ROOT/docker/docker-entrypoint.sh"
  HEALTHCHECK="$REPO_ROOT/docker/healthcheck.sh"
  unset "${ENTRYPOINT_ENV_VARS[@]}" STUB_EXIT STUB_SLEEP

  export STATE_DIR="$SANDBOX/state"
  mkdir -p "$STATE_DIR"
  STATUS_FILE="$STATE_DIR/last-run"

  # The stub appends one line per run to $STUB_LOG: its working directory, then each argument as <arg>.
  # With STUB_SLEEP it sleeps in a child process (like the script's wget) and records that child's pid.
  export STUB_LOG="$SANDBOX/stub.log"
  export KIWIX_ZIM_UPDATER="$SANDBOX/fake-updater"
  cat >"$KIWIX_ZIM_UPDATER" <<'EOF'
#!/usr/bin/env bash
line="$PWD"
for arg in "$@"; do line+=" <$arg>"; done
printf '%s\n' "$line" >>"$STUB_LOG"
if [[ -n "${STUB_SLEEP:-}" ]]; then
  sleep "$STUB_SLEEP" &
  echo "$!" >"$STUB_LOG.child"
  wait
fi
exit "${STUB_EXIT:-0}"
EOF
  chmod +x "$KIWIX_ZIM_UPDATER"
}

teardown() {
  # Never leave a background entrypoint or stub behind
  [[ -n "${BG_PID:-}" ]] && kill -KILL "$BG_PID" 2>/dev/null
  [[ -f "$STUB_LOG.child" ]] && kill -KILL "$(cat "$STUB_LOG.child")" 2>/dev/null
  return 0
}

# run_once [VAR=value...] - Run the entrypoint once in env mode and leave the stub's arguments in $output
run_once() {
  run env RUN_INTERVAL=once "$@" "$ENTRYPOINT"
  ENTRY_STATUS="$status"
  ENTRY_OUTPUT="$output"
}

# stub_args [<run>] - The arguments of a stub run (default: the last), without the working directory
stub_args() {
  local line
  if [[ -n "${1:-}" ]]; then line="$(sed -n "${1}p" "$STUB_LOG")"; else line="$(tail -n 1 "$STUB_LOG")"; fi
  printf '%s\n' "${line#* }"
}

stub_runs() {
  if [[ -f "$STUB_LOG" ]]; then wc -l <"$STUB_LOG"; else echo 0; fi
}

# wait_for <seconds> <command...> - Poll until a command succeeds
wait_for() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [[ $SECONDS -ge $deadline ]] && return 1
    sleep 0.1
  done
}

at_least_runs() { [[ "$(stub_runs)" -ge "$1" ]]; }
bg_stopped() { ! kill -0 "$BG_PID" 2>/dev/null; }

process_gone() { ! kill -0 "$1" 2>/dev/null; }

@test "entrypoint: defaults run a checksummed web dry-run with --clean-partials on /data" {
  run_once
  [[ "$ENTRY_STATUS" -eq 0 ]]
  run stub_args
  assert_output '<-w> <-c> <--clean-partials> </data>'
  refute_output --partial '<-d>'
  refute_output --partial '<-U>'
}

@test "entrypoint: the updater runs from STATE_DIR" {
  run_once
  run cat "$STUB_LOG"
  assert_output --regexp "^$STATE_DIR <"
}

@test "entrypoint: DRY_RUN=false adds -d" {
  run_once DRY_RUN=false
  run stub_args
  assert_output '<-d> <-w> <-c> <--clean-partials> </data>'
}

@test "entrypoint: booleans accept true/false/1/0/yes/no in any case" {
  local value
  for value in false FALSE 0 no No; do
    run_once DRY_RUN="$value"
    [[ "$ENTRY_STATUS" -eq 0 ]]
    run stub_args
    assert_output --partial '<-d>'
  done
  for value in true TRUE 1 yes YES; do
    run_once DRY_RUN="$value"
    run stub_args
    refute_output --partial '<-d>'
  done
}

@test "entrypoint: each variable maps to its option" {
  run_once CHECKSUM=no VERIFY_LIBRARY=yes SKIP_PURGE=1 NO_SHA=true CLEAN_PARTIALS=false FORCE_FETCH_INDEX=yes \
    MIN_SIZE=1M MAX_SIZE=2Gi MIN_FREE_SPACE=50G COUNTRY=DE LIBRARY_XML=/zims/library.xml ZIM_DIR=/zims
  [[ "$ENTRY_STATUS" -eq 0 ]]
  run stub_args
  assert_output '<-w> <-f> <-p> <-S> <-g> <-n> <1M> <-x> <2Gi> <--min-free> <50G> <-l> <DE> <--library> </zims/library.xml> </zims>'
}

@test "entrypoint: CHECKSUM=false drops -c and CLEAN_PARTIALS=false drops --clean-partials" {
  run_once CHECKSUM=false CLEAN_PARTIALS=false
  run stub_args
  assert_output '<-w> </data>'
}

@test "entrypoint: empty size, free-space and country variables add nothing" {
  run_once MIN_SIZE= MAX_SIZE= MIN_FREE_SPACE= COUNTRY= LIBRARY_XML= EXTRA_ARGS=
  run stub_args
  assert_output '<-w> <-c> <--clean-partials> </data>'
}

@test "entrypoint: DOWNLOAD_METHOD=torrent passes -t and never -c" {
  run_once DOWNLOAD_METHOD=torrent
  [[ "$ENTRY_STATUS" -eq 0 ]]
  run stub_args
  assert_output '<-t> <--clean-partials> </data>'
  run_once DOWNLOAD_METHOD=torrent CHECKSUM=true
  run stub_args
  assert_output '<-t> <--clean-partials> </data>'
}

@test "entrypoint: VERIFY_LIBRARY with torrent is a usage error" {
  run_once DOWNLOAD_METHOD=torrent VERIFY_LIBRARY=true
  [[ "$ENTRY_STATUS" -eq 2 ]]
  [[ "$ENTRY_OUTPUT" == *VERIFY_LIBRARY* ]]
  [[ "$(stub_runs)" -eq 0 ]]
}

@test "entrypoint: EXTRA_ARGS are word-split and appended before the ZIM directory" {
  run_once EXTRA_ARGS='-u  -l   FR'
  run stub_args
  assert_output '<-w> <-c> <--clean-partials> <-u> <-l> <FR> </data>'
}

@test "entrypoint: a multi-line EXTRA_ARGS keeps every line" {
  run_once EXTRA_ARGS=$'-S\n-p\n-x 2Gi'
  run stub_args
  assert_output '<-w> <-c> <--clean-partials> <-S> <-p> <-x> <2Gi> </data>'
}

@test "entrypoint: -U on a later line of EXTRA_ARGS is refused too" {
  run_once EXTRA_ARGS=$'-S\n-U'
  [[ "$ENTRY_STATUS" -eq 2 ]]
  [[ "$(stub_runs)" -eq 0 ]]
}

@test "entrypoint: EXTRA_ARGS are not glob-expanded" {
  touch "$STATE_DIR/match-me"
  run_once EXTRA_ARGS='*'
  run stub_args
  assert_output '<-w> <-c> <--clean-partials> <*> </data>'
}

@test "entrypoint: -U is refused in EXTRA_ARGS and in arguments" {
  run_once EXTRA_ARGS='-U'
  [[ "$ENTRY_STATUS" -eq 2 ]]
  run_once EXTRA_ARGS='--self-update'
  [[ "$ENTRY_STATUS" -eq 2 ]]
  run "$ENTRYPOINT" -U /data
  assert_failure 2
  [[ "$(stub_runs)" -eq 0 ]]
}

@test "entrypoint: an invalid boolean exits 2 with a message on stderr and runs nothing" {
  local var
  for var in DRY_RUN CHECKSUM VERIFY_LIBRARY SKIP_PURGE NO_SHA CLEAN_PARTIALS FORCE_FETCH_INDEX; do
    run --separate-stderr env RUN_INTERVAL=once "$var=maybe" "$ENTRYPOINT"
    assert_failure 2
    assert_output ''
    [[ "$stderr" == *"$var"*maybe* ]]
  done
  [[ "$(stub_runs)" -eq 0 ]]
  [[ ! -e "$STATUS_FILE" ]]
}

@test "entrypoint: an invalid DOWNLOAD_METHOD exits 2" {
  run --separate-stderr env RUN_INTERVAL=once DOWNLOAD_METHOD=ftp "$ENTRYPOINT"
  assert_failure 2
  [[ "$stderr" == *DOWNLOAD_METHOD* ]]
  [[ "$(stub_runs)" -eq 0 ]]
}

@test "entrypoint: an invalid RUN_INTERVAL exits 2 with a message on stderr" {
  local value
  for value in 1w -5 1.5h h 10ms 'once more'; do
    run --separate-stderr env RUN_INTERVAL="$value" "$ENTRYPOINT"
    assert_failure 2
    [[ "$stderr" == *RUN_INTERVAL* ]]
  done
  [[ "$(stub_runs)" -eq 0 ]]
}

@test "entrypoint: arguments are passed through verbatim and run once with the updater's exit code" {
  run env STUB_EXIT=3 DRY_RUN=false CHECKSUM=true EXTRA_ARGS=-g RUN_INTERVAL=1s "$ENTRYPOINT" -d -n '1 G' /some/dir
  assert_failure 3
  run cat "$STUB_LOG"
  assert_output "$STATE_DIR <-d> <-n> <1 G> </some/dir>"
  # One run only, and passing arguments is not a scheduled run: no status file
  [[ "$(stub_runs)" -eq 1 ]]
  [[ ! -e "$STATUS_FILE" ]]
}

@test "entrypoint: -h is passed through and exits 0" {
  run "$ENTRYPOINT" -h
  assert_success
  run stub_args
  assert_output '<-h>'
}

@test "entrypoint: the passed-through updater defaults to /usr/local/bin/kiwix-zim-updater.sh" {
  run grep -F 'KIWIX_ZIM_UPDATER="${KIWIX_ZIM_UPDATER:-/usr/local/bin/kiwix-zim-updater.sh}"' "$ENTRYPOINT"
  assert_success
}

@test "entrypoint: RUN_INTERVAL=once runs once and exits with the updater's exit code" {
  local value
  for value in once ONCE 0; do
    : >"$STUB_LOG"
    run env RUN_INTERVAL="$value" STUB_EXIT=1 "$ENTRYPOINT"
    assert_failure 1
    [[ "$(stub_runs)" -eq 1 ]]
  done
  run env RUN_INTERVAL=once STUB_EXIT=75 "$ENTRYPOINT"
  assert_failure 75
}

@test "entrypoint: each run logs one start and one end line to stdout" {
  run env RUN_INTERVAL=once STUB_EXIT=1 "$ENTRYPOINT"
  assert_line --regexp '^\[docker-entrypoint\] [0-9TZ:-]+ run 1 started: fake-updater -w -c --clean-partials /data$'
  assert_line --regexp '^\[docker-entrypoint\] [0-9TZ:-]+ run 1 failed: exit 1'
}

@test "entrypoint: when last-run cannot be written the loop stops with exit 1 instead of looking healthy" {
  # A previous successful run is on record; this run fails, but its status cannot replace the record
  printf 'exit=0 time=2026-01-01T00:00:00Z\n' >"$STATUS_FILE"
  rm -f "$STATUS_FILE" && mkdir "$STATUS_FILE"
  run timeout 20 env STUB_EXIT=1 RUN_INTERVAL=1s "$ENTRYPOINT"
  assert_failure 1
  assert_output --partial 'could not record run 1 (exit 1)'
  [[ "$(stub_runs)" -eq 1 ]]
  [[ -z "$(ls -A "$STATUS_FILE")" ]]
}

@test "entrypoint: a run whose status cannot be written is not followed by another one" {
  [[ $EUID -ne 0 ]] || skip "root can write to read-only directories"
  # STATE_DIR must be writable at start; make it read-only only once the first run is under way
  STUB_SLEEP=2 RUN_INTERVAL=1s "$ENTRYPOINT" >"$SANDBOX/out" 2>&1 3>&- &
  BG_PID=$!
  wait_for 15 at_least_runs 1
  chmod a-w "$STATE_DIR"
  # Bounded: with the bug the loop would go on forever
  local status=0 stopped=0
  wait_for 15 bg_stopped && stopped=1
  chmod u+w "$STATE_DIR"
  [[ $stopped -eq 1 ]] || { kill -TERM "$BG_PID"; wait "$BG_PID"; BG_PID=""; false; }
  wait "$BG_PID" || status=$?
  BG_PID=""
  [[ "$status" -eq 1 ]]
  [[ "$(stub_runs)" -eq 1 ]]
  run cat "$SANDBOX/out"
  assert_output --partial 'could not record run 1'
}

@test "entrypoint: last-run records the exit code and UTC time of the run" {
  local before after time
  before="$(date -u +%s)"
  run env RUN_INTERVAL=once STUB_EXIT=1 "$ENTRYPOINT"
  after="$(date -u +%s)"
  run cat "$STATUS_FILE"
  assert_output --regexp '^exit=1 time=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  time="$(date -u -d "$(sed -E 's/.*time=([^ ]+).*/\1/' "$STATUS_FILE")" +%s)"
  [[ "$time" -ge "$before" && "$time" -le "$after" ]]
  run env RUN_INTERVAL=once "$ENTRYPOINT"
  run cat "$STATUS_FILE"
  assert_output --regexp '^exit=0 time=[^ ]+$'
  # Written through a temporary file that does not stay behind
  run ls -A "$STATE_DIR"
  assert_output 'last-run'
}

@test "entrypoint: a STATE_DIR that does not exist exits 1 and runs nothing" {
  run env RUN_INTERVAL=once STATE_DIR="$SANDBOX/missing" "$ENTRYPOINT"
  assert_failure 1
  [[ "$(stub_runs)" -eq 0 ]]
}

@test "entrypoint: an overflowing RUN_INTERVAL is a usage error, not a back-to-back loop" {
  local value
  for value in 9223372036854775808s 9223372036854775807d 1000000000000d 0000000000000001s; do
    # timeout: with the overflow bug the loop would run back to back forever
    run --separate-stderr timeout 10 env RUN_INTERVAL="$value" "$ENTRYPOINT"
    assert_failure 2
    [[ "$stderr" == *"at most 12 digits"* ]]
  done
  [[ "$(stub_runs)" -eq 0 ]]
}

@test "entrypoint: the largest RUN_INTERVAL is accepted and really sleeps" {
  RUN_INTERVAL=999999999999d "$ENTRYPOINT" >"$SANDBOX/out" 2>&1 3>&- &
  BG_PID=$!
  wait_for 15 at_least_runs 1
  sleep 2
  [[ "$(stub_runs)" -eq 1 ]]
  kill -TERM "$BG_PID"
  wait "$BG_PID" || true
  BG_PID=""
}

@test "entrypoint: the loop keeps running after a failed run" {
  STUB_EXIT=1 RUN_INTERVAL=1s "$ENTRYPOINT" >"$SANDBOX/out" 2>&1 3>&- &
  BG_PID=$!
  wait_for 15 at_least_runs 2
  kill -TERM "$BG_PID"
  wait "$BG_PID" || true
  BG_PID=""
  run cat "$SANDBOX/out"
  assert_line --partial 'run 1 failed: exit 1'
  assert_line --partial 'run 2 started'
}

@test "entrypoint: the loop keeps running after exit 75 and stops cleanly on SIGTERM" {
  STUB_EXIT=75 RUN_INTERVAL=1s "$ENTRYPOINT" >"$SANDBOX/out" 2>&1 3>&- &
  BG_PID=$!
  wait_for 15 at_least_runs 2
  kill -TERM "$BG_PID"
  local status=0
  wait "$BG_PID" || status=$?
  BG_PID=""
  [[ "$status" -eq 0 ]]
  run cat "$SANDBOX/out"
  assert_line --partial 'run 2 skipped: another instance is running'
  assert_line --partial 'stopped by SIGTERM'
  run cat "$STATUS_FILE"
  assert_output --regexp '^exit=75 time=[^ ]+$'
}

@test "entrypoint: SIGTERM during a run is forwarded to the updater and its children, and recorded" {
  STUB_SLEEP=60 RUN_INTERVAL=1h "$ENTRYPOINT" >"$SANDBOX/out" 2>&1 3>&- &
  BG_PID=$!
  wait_for 15 test -s "$STUB_LOG.child"
  local child start=$SECONDS status=0
  child="$(cat "$STUB_LOG.child")"
  kill -TERM "$BG_PID"
  wait "$BG_PID" || status=$?
  BG_PID=""
  # The stub died of SIGTERM (143) well before its 60s sleep was over, and so did its child
  [[ "$status" -eq 143 ]]
  [[ $((SECONDS - start)) -lt 30 ]]
  wait_for 5 process_gone "$child"
  [[ "$(stub_runs)" -eq 1 ]]
  run cat "$STATUS_FILE"
  assert_output --regexp '^exit=143 time=[^ ]+ interrupted=TERM$'
  run cat "$SANDBOX/out"
  assert_line --partial 'run 1 interrupted by SIGTERM'
}

@test "entrypoint: SIGINT during a run stops the updater and its children" {
  # bash starts background jobs with SIGINT ignored; restore it, as it is for the entrypoint under tini
  STUB_SLEEP=60 RUN_INTERVAL=1h env --default-signal=INT "$ENTRYPOINT" >"$SANDBOX/out" 2>&1 3>&- &
  BG_PID=$!
  wait_for 15 test -s "$STUB_LOG.child"
  local child start=$SECONDS status=0
  child="$(cat "$STUB_LOG.child")"
  kill -INT "$BG_PID"
  wait "$BG_PID" || status=$?
  BG_PID=""
  [[ "$status" -eq 143 ]]
  [[ $((SECONDS - start)) -lt 30 ]]
  wait_for 5 process_gone "$child"
  run cat "$STATUS_FILE"
  assert_output --regexp '^exit=143 time=[^ ]+ interrupted=INT$'
}

@test "entrypoint: SIGINT during the sleep between runs stops without another run" {
  RUN_INTERVAL=1h env --default-signal=INT "$ENTRYPOINT" >"$SANDBOX/out" 2>&1 3>&- &
  BG_PID=$!
  wait_for 15 grep -q 'next run in 1h' "$SANDBOX/out"
  kill -INT "$BG_PID"
  local status=0
  wait "$BG_PID" || status=$?
  BG_PID=""
  [[ "$status" -eq 0 ]]
  [[ "$(stub_runs)" -eq 1 ]]
  run cat "$STATUS_FILE"
  assert_output --regexp '^exit=0 time=[^ ]+$'
  run cat "$SANDBOX/out"
  assert_line --partial 'stopped by SIGINT'
}

@test "entrypoint: a dry-run of the real script from the entrypoint leaves the ZIM directory alone" {
  make_local_zim wikipedia_en_test_2025-12.zim
  make_local_zim small_test_2025-11.zim
  local before
  before="$(zim_dir_snapshot)"
  run env RUN_INTERVAL=once KIWIX_ZIM_UPDATER="$SCRIPT_COPY" ZIM_DIR="$ZIMS" "$ENTRYPOINT"
  assert_success
  assert_output --partial '*** Simulated *** New zim exists, old zim purged'
  [[ "$(zim_dir_snapshot)" == "$before" ]]
  run wget_downloads
  assert_output ''
  # The log and the index cache land in STATE_DIR, next to the status
  [[ -s "$STATE_DIR/download.log" && -s "$STATE_DIR/kiwix-index" ]]
  run cat "$STATUS_FILE"
  assert_output --regexp '^exit=0 '
}

@test "healthcheck: healthy when no run has finished yet" {
  run "$HEALTHCHECK"
  assert_success
}

@test "healthcheck: healthy after exit 0 and exit 75" {
  echo 'exit=0 time=2026-10-25T12:00:00Z' >"$STATUS_FILE"
  run "$HEALTHCHECK"
  assert_success
  echo 'exit=75 time=2026-10-25T12:00:00Z' >"$STATUS_FILE"
  run "$HEALTHCHECK"
  assert_success
}

@test "healthcheck: unhealthy after a failed run" {
  local code
  for code in 1 2 127; do
    echo "exit=$code time=2026-10-25T12:00:00Z" >"$STATUS_FILE"
    run "$HEALTHCHECK"
    assert_failure 1
    assert_output --partial "exit=$code"
  done
}

@test "healthcheck: a run interrupted by a stop is not a failure" {
  echo 'exit=143 time=2026-10-25T12:00:00Z interrupted=TERM' >"$STATUS_FILE"
  run "$HEALTHCHECK"
  assert_success
}

@test "healthcheck: an unreadable status is unhealthy" {
  echo 'garbage' >"$STATUS_FILE"
  run "$HEALTHCHECK"
  assert_failure 1
  : >"$STATUS_FILE"
  run "$HEALTHCHECK"
  assert_failure 1
}

@test "healthcheck: follows what the entrypoint wrote" {
  run env RUN_INTERVAL=once STUB_EXIT=1 "$ENTRYPOINT"
  run "$HEALTHCHECK"
  assert_failure 1
  run env RUN_INTERVAL=once STUB_EXIT=0 "$ENTRYPOINT"
  run "$HEALTHCHECK"
  assert_success
}
