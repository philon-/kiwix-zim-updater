#!/usr/bin/env bats
# The Makefile's tool selection (dry runs only: nothing is executed).

bats_require_minimum_version 1.5.0

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
