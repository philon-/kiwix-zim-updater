# Test and lint entry points. See AGENTS.md.

BATS ?= test/libs/bats-core/bin/bats
SHELLCHECK_SEVERITY ?= style
SHELLCHECK_IMAGE ?= docker.io/koalaman/shellcheck:v0.10.0

# Container engine for the ShellCheck fallback and for `make docker-build`/`docker-test`/`library-test` (podman if
# installed, otherwise docker).
CONTAINER_ENGINE ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

# Use a local shellcheck when available, otherwise the pinned container image with CONTAINER_ENGINE.
SHELLCHECK_LOCAL ?= $(shell command -v shellcheck 2>/dev/null)
ifneq ($(SHELLCHECK_LOCAL),)
SHELLCHECK ?= $(SHELLCHECK_LOCAL)
else ifneq ($(CONTAINER_ENGINE),)
SHELLCHECK ?= $(CONTAINER_ENGINE) run --rm -v "$(CURDIR):/mnt:Z" -w /mnt $(SHELLCHECK_IMAGE)
endif

# Files checked at SHELLCHECK_SEVERITY (the script, the container scripts and their tests, default: every finding)
# and at the default severity (everything written for the test harness).
SCRIPT := kiwix-zim-updater.sh
CONTAINER_SCRIPTS := docker/docker-entrypoint.sh docker/healthcheck.sh test/docker-smoke.sh test/library-integration.sh
HARNESS_SCRIPTS := $(wildcard test/helpers/bin/*) $(wildcard test/fixtures/build.sh)
HARNESS_LIBS := $(wildcard test/helpers/*.bash)

# Image tag for `make docker-build`, `make docker-test` and `make library-test`.
IMAGE ?= localhost/kiwix-zim-updater:test
# Stamped into the image, which has no git clone: the version -v reports, the date and short hash of the checked-out
# commit. Expanded only by docker-build; set IMAGE_VERSION= to build an image that reports "unknown".
IMAGE_VERSION ?= $(shell git log -1 --no-show-signature --date=format:%Y.%m.%d --format=%cd+%h 2>/dev/null)
# podman's default OCI image format drops HEALTHCHECK
BUILD_OPTS ?= $(if $(filter podman%,$(notdir $(CONTAINER_ENGINE))),--format docker)

# Expanded at the start of a recipe: stop with a clear message when a tool it needs is missing
need_shellcheck = $(if $(SHELLCHECK),,$(error $@: neither shellcheck nor podman or docker found))
need_engine = $(if $(CONTAINER_ENGINE),,$(error $@: neither podman nor docker found; set CONTAINER_ENGINE))

.PHONY: all test lint docker-build docker-test library-test

all: lint test

test:
	$(BATS) test/

lint:
	$(need_shellcheck)
	$(SHELLCHECK) --severity=$(SHELLCHECK_SEVERITY) -x $(SCRIPT) $(CONTAINER_SCRIPTS)
	$(SHELLCHECK) $(HARNESS_SCRIPTS)
	$(SHELLCHECK) -s bash $(HARNESS_LIBS)

# Build the container image as IMAGE.
docker-build:
	$(need_engine)
	$(CONTAINER_ENGINE) build $(BUILD_OPTS) $(if $(IMAGE_VERSION),--build-arg VERSION=$(IMAGE_VERSION)) -t $(IMAGE) .

# Smoke-test the image offline with the test stubs. Not part of `make test`.
docker-test: docker-build
	CONTAINER_ENGINE="$(CONTAINER_ENGINE)" IMAGE="$(IMAGE)" test/docker-smoke.sh

# End-to-end test of --library with real ZIMs, the image's kiwix-manage and the official kiwix-serve image.
library-test: docker-build
	CONTAINER_ENGINE="$(CONTAINER_ENGINE)" IMAGE="$(IMAGE)" test/library-integration.sh
