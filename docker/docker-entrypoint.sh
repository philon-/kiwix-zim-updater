#!/usr/bin/env bash
# Container entrypoint for kiwix-zim-updater.sh. See "Running with Docker" in README.md.
#
# With arguments, the updater runs once with exactly those arguments and the container exits with its exit code:
#   docker run --rm -v /srv/zims:/data kiwix-zim-updater -h
# Without arguments, the options are built from environment variables (see compose.example.yaml) and the updater
# runs right away and then again every RUN_INTERVAL. Each finished run is recorded in "$STATE_DIR/last-run", which
# healthcheck.sh reads.
#
# The updater always runs from $STATE_DIR, so its download.log and kiwix-index cache land there and never in the ZIM
# directory. SIGTERM and SIGINT are forwarded to the running updater and everything it started (wget), so an
# interrupted download stays a .part file that the next run resumes.

# Defaults for the environment variables that have one; empty counts as unset. The other variables are read in
# build_args. healthcheck.sh repeats the STATE_DIR default and the last-run file name: keep them in step. Tests point
# KIWIX_ZIM_UPDATER, the updater to run, at a stub.
KIWIX_ZIM_UPDATER="${KIWIX_ZIM_UPDATER:-/usr/local/bin/kiwix-zim-updater.sh}"
STATE_DIR="${STATE_DIR:-/state}"
ZIM_DIR="${ZIM_DIR:-/data}"
RUN_INTERVAL="${RUN_INTERVAL:-24h}"
STATUS_FILE="$STATE_DIR/last-run"

child_pid=""   # the running updater, if any
sleep_pid=""   # the sleep between runs, if any
stop_signal="" # set once SIGTERM or SIGINT arrived
updater_args=()

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

log() {
  printf '[docker-entrypoint] %s %s\n' "$(utc_now)" "$*"
}

# usage_error <message> - A bad environment variable or argument: report it on stderr and exit 2
usage_error() {
  printf '[docker-entrypoint] %s\n' "$1" >&2
  exit 2
}

# read_bool <variable name> <default> - Print 1 or 0 for a boolean environment variable. Empty means the default; a
# value that is not a boolean is a usage error.
read_bool() {
  local value="${!1:-}"
  [[ -z "$value" ]] && value="$2"
  case "${value,,}" in
    true | 1 | yes) echo 1 ;;
    false | 0 | no) echo 0 ;;
    *) usage_error "$1 must be one of true, false, 1, 0, yes or no, got '${!1}'" ;;
  esac
}

# interval_seconds <interval> - Print RUN_INTERVAL in seconds: 0 for "once" or 0, otherwise <n>[smhd]. At most 12
# digits, so that even <n>d stays far below the 64-bit limit: a wrapped (negative) interval would make sleep fail at
# once and the loop run the updater back to back.
interval_seconds() {
  local value="${1,,}" number unit
  [[ "$value" == "once" ]] && { echo 0; return 0; }
  [[ "$value" =~ ^([0-9]{1,12})([smhd]?)$ ]] || return 1
  number=$((10#${BASH_REMATCH[1]}))
  unit="${BASH_REMATCH[2]}"
  case "$unit" in
    m) number=$((number * 60)) ;;
    h) number=$((number * 3600)) ;;
    d) number=$((number * 86400)) ;;
  esac
  echo "$number"
}

# refuse_self_update <args...> - The image has no git clone to update; a new version comes with a new image
refuse_self_update() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -U | --self-update) usage_error "$arg is not supported in the container: pull or build a new image instead." ;;
    esac
  done
}

# build_args - Fill updater_args from the environment, or exit 2 on an invalid value
build_args() {
  local dry_run checksum verify method spec name default option value extra=() options=()
  # DRY_RUN, CHECKSUM, VERIFY_LIBRARY and DOWNLOAD_METHOD depend on each other: they are handled below
  dry_run="$(read_bool DRY_RUN true)" || exit 2
  checksum="$(read_bool CHECKSUM true)" || exit 2
  verify="$(read_bool VERIFY_LIBRARY false)" || exit 2

  # Plain switches: <variable> <default> <option added when true>
  for spec in "SKIP_PURGE false -p" "NO_SHA false -S" "CLEAN_PARTIALS true --clean-partials" \
    "FORCE_FETCH_INDEX false -g"; do
    read -r name default option <<<"$spec"
    value="$(read_bool "$name" "$default")" || exit 2
    [[ "$value" -eq 1 ]] && options+=("$option")
  done
  # Options with a value: <variable> <option added with the value when the variable is not empty>
  for spec in "MIN_SIZE -n" "MAX_SIZE -x" "MIN_FREE_SPACE --min-free" "COUNTRY -l" "LIBRARY_XML --library"; do
    read -r name option <<<"$spec"
    [[ -n "${!name:-}" ]] && options+=("$option" "${!name}")
  done

  method="${DOWNLOAD_METHOD:-web}"
  case "${method,,}" in
    web) method=web ;;
    torrent) method=torrent ;;
    *) usage_error "DOWNLOAD_METHOD must be web or torrent, got '$method'" ;;
  esac
  # The updater checks a checksum only for web downloads and rejects -c and -f together with -t
  if [[ "$method" == "torrent" ]]; then
    [[ "$verify" -eq 1 ]] && usage_error "VERIFY_LIBRARY=true cannot be combined with DOWNLOAD_METHOD=torrent"
    checksum=0
  fi

  # Split EXTRA_ARGS on whitespace, newlines included (a multi-line YAML value must not lose its later lines), without
  # glob expansion. read returns 1 at the end of input, which is expected here.
  read -r -d '' -a extra <<<"${EXTRA_ARGS:-}" || true
  refuse_self_update "${extra[@]}"

  updater_args=()
  [[ "$dry_run" -eq 0 ]] && updater_args+=(-d)
  if [[ "$method" == "torrent" ]]; then
    updater_args+=(-t)
  else
    updater_args+=(-w)
  fi
  [[ "$checksum" -eq 1 ]] && updater_args+=(-c)
  [[ "$verify" -eq 1 ]] && updater_args+=(-f)
  updater_args+=("${options[@]}" "${extra[@]}" "$ZIM_DIR")
}

# on_signal <signal> - Forward a stop request to the running updater (its whole process group, so wget and tee get
# it too) and end the sleep between runs. The main loop then waits for the updater and exits. The updater always
# gets SIGTERM: bash starts background processes with SIGINT ignored, so a forwarded SIGINT would not stop it.
on_signal() {
  stop_signal="$1"
  if [[ -n "$child_pid" ]]; then
    kill -s TERM -- "-$child_pid" 2>/dev/null || kill -s TERM "$child_pid" 2>/dev/null
  fi
  [[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null
}

# run_updater <args...> - Run the updater in its own process group and wait for it, also across signals. Sets
# run_status to its exit code.
run_updater() {
  local status
  setsid "$KIWIX_ZIM_UPDATER" "$@" &
  child_pid=$!
  # A signal that arrived while the updater was being started has not reached it yet
  [[ -n "$stop_signal" ]] && on_signal "$stop_signal"
  # wait returns early (with 128 + the signal number) when a trapped signal arrives: keep waiting until the updater
  # is really gone, then ask once more, because bash keeps the real exit code of a finished background process
  while :; do
    wait "$child_pid"
    run_status=$?
    kill -0 "$child_pid" 2>/dev/null || break
  done
  wait "$child_pid" 2>/dev/null
  status=$?
  [[ "$status" -ne 127 ]] && run_status="$status"
  child_pid=""
}

# write_status <exit code> - Record the finished run in $STATUS_FILE, atomically for healthcheck.sh. Returns 1 when it
# cannot (-T: a directory in its place must be an error, not a place to move the file into).
write_status() {
  local line tmp
  line="exit=$1 time=$(utc_now)"
  [[ -n "$stop_signal" ]] && line+=" interrupted=$stop_signal"
  tmp="$STATUS_FILE.tmp.$$"
  if printf '%s\n' "$line" >"$tmp" 2>/dev/null && mv -fT "$tmp" "$STATUS_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

main() {
  trap 'on_signal TERM' TERM
  trap 'on_signal INT' INT

  # Check the arguments or the environment first: a bad value is a usage error, whatever the state directory
  local interval run=0 status
  if [[ $# -gt 0 ]]; then
    refuse_self_update "$@"
  else
    interval="$(interval_seconds "$RUN_INTERVAL")" ||
      usage_error "RUN_INTERVAL must be once, 0 or <number>[s|m|h|d] with at most 12 digits, got '$RUN_INTERVAL'"
    build_args
  fi

  if ! cd "$STATE_DIR" 2>/dev/null; then
    printf '[docker-entrypoint] cannot change to the state directory %s\n' "$STATE_DIR" >&2
    exit 1
  fi

  # Arguments given: run once with exactly those arguments
  if [[ $# -gt 0 ]]; then
    run_updater "$@"
    exit "$run_status"
  fi

  if [[ ! -w "$STATE_DIR" ]]; then
    printf '[docker-entrypoint] the state directory %s is not writable by uid %s\n' "$STATE_DIR" "$(id -u)" >&2
    exit 1
  fi

  while [[ -z "$stop_signal" ]]; do
    run=$((run + 1))
    log "run $run started: $(basename "$KIWIX_ZIM_UPDATER") ${updater_args[*]}"
    run_updater "${updater_args[@]}"
    status="$run_status"
    if ! write_status "$status"; then
      # A stale or missing record would let the health check report the wrong state: stop, so the failure shows (the
      # restart policy then makes it visible as a restarting container)
      log "error: could not record run $run (exit $status) in $STATUS_FILE; stopping"
      exit 1
    fi
    if [[ -n "$stop_signal" ]]; then
      log "run $run interrupted by SIG$stop_signal (exit $status); an unfinished download is resumed by the next run"
      exit "$status"
    fi
    case "$status" in
      0) log "run $run finished: exit 0" ;;
      75) log "run $run skipped: another instance is running on $ZIM_DIR (exit 75)" ;;
      *) log "run $run failed: exit $status, see $STATE_DIR/download.log" ;;
    esac

    if [[ "$interval" -eq 0 ]]; then
      exit "$status"
    fi

    log "next run in $RUN_INTERVAL"
    sleep "$interval" &
    sleep_pid=$!
    # A signal that arrived just before the sleep started has nothing to end yet
    [[ -n "$stop_signal" ]] && kill "$sleep_pid" 2>/dev/null
    wait "$sleep_pid" 2>/dev/null
    sleep_pid=""
  done
  log "stopped by SIG$stop_signal"
  exit 0
}

main "$@"
