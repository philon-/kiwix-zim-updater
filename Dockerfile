# Container image for kiwix-zim-updater. See "Running with Docker" in README.md and compose.example.yaml.
#
#   docker build -t kiwix-zim-updater .
#   podman build --format docker -t kiwix-zim-updater .   # --format docker keeps the HEALTHCHECK
#
# The base image is pinned by tag. For reproducible builds, pin its digest as well, e.g.
#   FROM docker.io/library/debian:trixie-slim@sha256:<digest>
# where <digest> is printed by `docker pull docker.io/library/debian:trixie-slim` (or
# `podman image inspect --format '{{.Digest}}' docker.io/library/debian:trixie-slim`).
FROM docker.io/library/debian:trixie-slim

LABEL org.opencontainers.image.title="kiwix-zim-updater" \
      org.opencontainers.image.description="Keeps a local Kiwix ZIM library up to date with download.kiwix.org" \
      org.opencontainers.image.source="https://github.com/philon-/kiwix-zim-updater" \
      org.opencontainers.image.licenses="GPL-2.0-only"

# Only what the script needs: GNU coreutils (numfmt, stat, du, sha256sum, timeout, date), grep -P, flock from
# util-linux, wget with CA certificates, and tini as PID 1. No git: the image never updates itself (-U).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash coreutils grep util-linux wget ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged user. Run the container with --user (compose: user:) to match the owner of your ZIM directory.
RUN groupadd --gid 1000 kiwix \
    && useradd --uid 1000 --gid 1000 --home-dir /state --no-create-home --shell /usr/sbin/nologin kiwix \
    && mkdir -p /data /state \
    && chown kiwix:kiwix /data /state

COPY kiwix-zim-updater.sh docker/docker-entrypoint.sh docker/healthcheck.sh /usr/local/bin/

# /data: the ZIM directory. /state: the working directory (download.log, kiwix-index cache, last-run status).
VOLUME ["/data", "/state"]
WORKDIR /state
USER 1000:1000

# The status changes only when a run finishes, so checking every few minutes is plenty.
HEALTHCHECK --interval=5m --timeout=10s --start-period=1m --retries=1 CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
