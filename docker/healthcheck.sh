#!/usr/bin/env bash
# Container health check for kiwix-zim-updater, run by the image's HEALTHCHECK.
#
# Reads the status of the last finished run that docker-entrypoint.sh wrote to "$STATE_DIR/last-run":
#   healthy (0)   no run has finished yet, the last run exited 0 or 75 (another instance was busy), or it was
#                 interrupted by a container stop;
#   unhealthy (1) the last run failed, e.g. with exit 1 during an internet outage, or the status is unreadable.
# Being unhealthy changes nothing: the ZIMs in the ZIM directory stay as they are and the next run tries again.

status_file="${STATE_DIR:-/state}/last-run"

if [[ ! -e "$status_file" ]]; then
  echo "no run has finished yet"
  exit 0
fi

if ! line="$(<"$status_file")"; then
  echo "cannot read $status_file"
  exit 1
fi

if [[ ! "$line" =~ ^exit=([0-9]+)([[:space:]]|$) ]]; then
  echo "unreadable status in $status_file: $line"
  exit 1
fi

case "${BASH_REMATCH[1]}" in
  0 | 75)
    echo "last run ok: $line"
    exit 0
    ;;
esac

if [[ "$line" =~ [[:space:]]interrupted= ]]; then
  echo "last run was interrupted by a stop: $line"
  exit 0
fi

echo "last run failed: $line"
exit 1
