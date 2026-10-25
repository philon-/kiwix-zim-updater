# Test and lint entry points. See AGENTS.md.

BATS ?= test/libs/bats-core/bin/bats
SHELLCHECK_SEVERITY ?= style
SHELLCHECK_IMAGE ?= docker.io/koalaman/shellcheck:v0.10.0

# Container engine for the ShellCheck fallback and for `make docker-test`/`make library-test` (podman if installed,
# otherwise docker).
CONTAINER_ENGINE ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

# Use a local shellcheck when available, otherwise the pinned container image with CONTAINER_ENGINE.
SHELLCHECK_LOCAL ?= $(shell command -v shellcheck 2>/dev/null)
ifeq ($(SHELLCHECK_LOCAL),)
SHELLCHECK ?= $(CONTAINER_ENGINE) run --rm -v "$(CURDIR):/mnt:Z" -w /mnt $(SHELLCHECK_IMAGE)
else
SHELLCHECK ?= $(SHELLCHECK_LOCAL)
endif

# Files checked at SHELLCHECK_SEVERITY (the script and the container scripts, default: every finding)
# and at the default severity (everything written for the test harness).
SCRIPT := kiwix-zim-updater.sh
DOCKER_SCRIPTS := docker/docker-entrypoint.sh docker/healthcheck.sh test/docker-smoke.sh test/library-integration.sh
HARNESS_SCRIPTS := $(wildcard test/helpers/bin/*) $(wildcard test/fixtures/build.sh)
HARNESS_LIBS := $(wildcard test/helpers/*.bash)

# Image tag for `make docker-test` and `make library-test`.
IMAGE ?= localhost/kiwix-zim-updater:test

.PHONY: all test lint docker-test library-test

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

# End-to-end test of --library with real ZIMs, the image's kiwix-manage and the official kiwix-serve image.
library-test:
	CONTAINER_ENGINE="$(CONTAINER_ENGINE)" IMAGE="$(IMAGE)" test/library-integration.sh
