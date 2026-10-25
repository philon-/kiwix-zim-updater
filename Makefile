# Test and lint entry points. See AGENTS.md.

BATS ?= test/libs/bats-core/bin/bats
SHELLCHECK_SEVERITY ?= style
SHELLCHECK_IMAGE ?= docker.io/koalaman/shellcheck:v0.10.0

# Use a local shellcheck when available, otherwise a pinned container image.
ifeq ($(shell command -v shellcheck 2>/dev/null),)
SHELLCHECK ?= podman run --rm -v "$(CURDIR):/mnt:Z" -w /mnt $(SHELLCHECK_IMAGE)
else
SHELLCHECK ?= shellcheck
endif

# Files checked at SHELLCHECK_SEVERITY (the script and the container scripts, default: every finding)
# and at the default severity (everything written for the test harness).
SCRIPT := kiwix-zim-updater.sh
DOCKER_SCRIPTS := docker/docker-entrypoint.sh docker/healthcheck.sh test/docker-smoke.sh
HARNESS_SCRIPTS := $(wildcard test/helpers/bin/*) $(wildcard test/fixtures/build.sh)
HARNESS_LIBS := $(wildcard test/helpers/*.bash)

# Container engine and image tag for `make docker-test` (podman if installed, otherwise docker).
CONTAINER_ENGINE ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
IMAGE ?= localhost/kiwix-zim-updater:test

.PHONY: all test lint docker-test

all: lint test

test:
	$(BATS) test/

lint:
	$(SHELLCHECK) --severity=$(SHELLCHECK_SEVERITY) $(SCRIPT) $(DOCKER_SCRIPTS)
	$(if $(strip $(HARNESS_SCRIPTS)),$(SHELLCHECK) $(HARNESS_SCRIPTS))
	$(if $(strip $(HARNESS_LIBS)),$(SHELLCHECK) -s bash $(HARNESS_LIBS))

# Build the container image and smoke-test it offline with the test stubs. Not part of `make test`.
docker-test:
	CONTAINER_ENGINE="$(CONTAINER_ENGINE)" IMAGE="$(IMAGE)" test/docker-smoke.sh
