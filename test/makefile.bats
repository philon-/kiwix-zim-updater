#!/usr/bin/env bats
# The Makefile's tool selection (dry runs only: nothing is executed).

setup() {
  load 'helpers/common'
  common_setup
}

@test "make lint: without a local shellcheck the container fallback uses CONTAINER_ENGINE" {
  run make -n -C "$REPO_ROOT" lint SHELLCHECK_LOCAL= CONTAINER_ENGINE=docker
  assert_success
  assert_line --partial 'docker run --rm -v'
  refute_output --partial 'podman'
}

@test "make lint: a local shellcheck is used when there is one" {
  run make -n -C "$REPO_ROOT" lint SHELLCHECK_LOCAL=/usr/bin/shellcheck CONTAINER_ENGINE=docker
  assert_success
  assert_line --partial '/usr/bin/shellcheck --severity='
  refute_output --partial 'docker run'
}

@test "make lint: stops with a clear message without shellcheck and without a container engine" {
  run make -n -C "$REPO_ROOT" lint SHELLCHECK_LOCAL= CONTAINER_ENGINE=
  assert_failure
  assert_output --partial 'lint: neither shellcheck nor podman or docker found'
}

@test "make docker-build: podman builds in the docker format, which keeps HEALTHCHECK" {
  run make -n -C "$REPO_ROOT" docker-build CONTAINER_ENGINE=/usr/bin/podman IMAGE=img:t IMAGE_VERSION=2026.01.02+abc1234
  assert_success
  assert_line '/usr/bin/podman build --format docker --build-arg VERSION=2026.01.02+abc1234 -t img:t .'
}

@test "make docker-build: docker builds without --format" {
  run make -n -C "$REPO_ROOT" docker-build CONTAINER_ENGINE=docker IMAGE=img:t IMAGE_VERSION=2026.01.02+abc1234
  assert_success
  assert_line --regexp '^docker build +--build-arg VERSION=2026\.01\.02\+abc1234 -t img:t \.$'
}

@test "make docker-build: an empty IMAGE_VERSION passes no version" {
  run make -n -C "$REPO_ROOT" docker-build CONTAINER_ENGINE=docker IMAGE=img:t IMAGE_VERSION=
  assert_success
  assert_line --regexp '^docker build +-t img:t \.$'
}

@test "make docker-build: stops with a clear message without a container engine" {
  run make -n -C "$REPO_ROOT" docker-build CONTAINER_ENGINE= IMAGE_VERSION=
  assert_failure
  assert_output --partial 'docker-build: neither podman nor docker found'
}

@test "make docker-test and library-test: build the image first, then run their script" {
  local target script
  for target in docker-test:docker-smoke.sh library-test:library-integration.sh; do
    script="${target#*:}"
    run make -n --no-print-directory -C "$REPO_ROOT" "${target%%:*}" CONTAINER_ENGINE=docker IMAGE=img:t IMAGE_VERSION=
    assert_success
    assert_line --index 0 --regexp '^docker build +-t img:t \.$'
    assert_line --index 1 "CONTAINER_ENGINE=\"docker\" IMAGE=\"img:t\" test/$script"
  done
}
