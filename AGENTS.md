# AGENTS.md

These are guardrails for AI agents and humans working on this repository. Read this file before you change anything.

## What this is

`kiwix-zim-updater.sh` is a single Bash script. It compares the ZIM files in a local directory against the Kiwix catalog, downloads newer versions and deletes (purges) the old ones. Users run it unattended from cron against libraries that can be hundreds of GB. **A bug in this script destroys user data or wastes days of bandwidth.** Treat every change to download, verify and purge logic as safety-critical.

The repository is a private fork of the upstream https://github.com/jojo2357/kiwix-zim-updater.

## Layout

| Path | Purpose |
|---|---|
| `kiwix-zim-updater.sh` | The script. |
| `test/*.bats` | bats-core test suites. |
| `test/cli.bats`, `test/update_detection.bats`, `test/download.bats`, `test/verify.bats` | Characterization tests that pin the behaviour of the script. |
| `test/known_bugs.bats` | One regression test per review finding (F, H, M, N IDs). |
| `test/stubs.bats` | Self-tests for the stubs and the fixtures. |
| `test/p2_cli.bats`, `test/p2_ops.bats`, `test/p2_hygiene.bats` | Phase 2: exit codes and argument validation, dependency check, locking and index caching, global initialisation, ZIM listing and `-S`. |
| `test/p3_*.bats` | Phase 3: structure (`main()` and the source guard), the legacy-name removal and the opt-in self-update. |
| `test/p5_review.bats` | Regression tests for the independent reviews' findings. |
| `test/p6_followups.bats`, `test/p7_partials.bats` | Follow-ups: size limits on resumes, checksum-file timing, `.part` staging and the cleanup of unfinished downloads. |
| `test/p8_unattended.bats` | Unattended safety: network limits, the `--min-free` reserve, and that an internet outage leaves the ZIM directory unchanged. |
| `test/unit.bats` | Unit tests. They `source` the script and call its functions directly. |
| `test/docker_entrypoint.bats` | Tests of the container entrypoint and health check, with a stub updater. No Docker needed. |
| `test/docker-smoke.sh` | `make docker-test`: smoke-tests the image (built first by `make docker-build`) offline with the stubs. Not part of `make test`. |
| `test/library-integration.sh` | `make library-test`: `--library` end to end with real ZIMs (built with zimwriterfs), the image's kiwix-manage and the official kiwix-serve image. Not part of `make test`. |
| `test/makefile.bats` | The Makefile's tool selection (`make -n` only). |
| `test/p9_library.bats` | `--library`, with a `kiwix-manage` stub (in `test/helpers/bin/`) that writes the real library format. |
| `test/helpers/common.bash` | Shared setup. It creates a sandbox, copies the script there and prepends the stub `PATH`. |
| `test/helpers/container.bash` | Shared setup of `test/docker-smoke.sh` and `test/library-integration.sh`: container engine, image check, checks and cleanup. |
| `test/helpers/bin/` | Stubs for `wget`, `clear`, `git`, `df` and `kiwix-manage`, so tests never touch the network or the real repository, and free-space checks do not depend on the machine. |
| `test/fixtures/` | A fake catalog, `.meta4` files and payloads served by the `wget` stub. `build.sh` regenerates them. |
| `test/libs/` | Pinned git submodules for bats-core, bats-support and bats-assert. |
| `Dockerfile`, `.dockerignore` | The container image (`debian:trixie-slim`, non-root, `tini`). |
| `docker/docker-entrypoint.sh` | Container entrypoint: maps environment variables to options and runs the script on a schedule from `/state`. |
| `docker/healthcheck.sh` | Container health check: reads the last run's status from `/state/last-run`. |
| `compose.example.yaml` | Example Compose file with every environment variable documented. |
| `Makefile` | `make test`, `make lint`, `make docker-build`, `make docker-test`, `make library-test`. |
| `.github/workflows/ci.yml` | CI runs lint and tests on every push and pull request, and `make docker-test` and `make library-test` with Docker. |

Set up and run everything with:

```sh
git submodule update --init --recursive
make lint test
```

## Hard rules

1. **Never run the script outside the test sandbox.** That rules out real ZIM directories, `-d`/`--disable-dry-run` and the repository working tree as the current directory. The script writes `download.log` and `kiwix-index` into the current directory. Self-update now only runs with `-U`/`--self-update`, but with `-U` it runs `git fetch` and `git pull` on the clone it lives in, so never pass `-U` outside the sandbox either. Tests that exercise `-U` must use throwaway repositories inside the sandbox and must never read or change the user's global or system git config: set `HOME` and `GIT_CONFIG_GLOBAL` to paths inside the sandbox and `GIT_CONFIG_NOSYSTEM=1`, and never run `git config --global`.
2. **Never contact kiwix.org from tests.** All network access goes through the `wget` stub in `test/helpers/bin/`. The one exception is a manual, read-only, dry-run check that a human explicitly asks for.
3. **Dry-run is sacred.** While `DEBUG=1` (the default, i.e. no `-d`), nothing inside the ZIM directory may be created, modified or deleted. That includes `.sha256` files, lock files and torrents. Writing `download.log` and `kiwix-index` in the current directory is allowed.
4. **No unverified files under a ZIM's name, and no unverified deletes.** Downloads go into `<name>.zim.part` and are renamed only after every check passed; never download straight into a `.zim` name. The only exception is finishing a lone `.~lock.`-marked download left by an older version, in place, because moving it would drop it out of the ZIM listing. Every code path that runs `rm` on a ZIM must be preceded by either:
   - a replacement whose download succeeded and whose size was verified, plus its checksum when `-c` is set; or
   - an explicit user flag that requests the deletion.

   If in doubt, keep the old file.
5. **Do not weaken a test to make it pass.** If a test is wrong, fix it and explain the reason in the commit message.
6. **No push and no pull request without the user's explicit approval.**

## Workflow

- **Fix with a test.** Write a test that fails, or that is `skip`ped with the finding ID such as `skip "F1: ..."`, before you change the script. Then fix the script and remove the skip.
- **Make atomic commits.**
  - Each commit holds one logical change with its test.
  - `make lint test` must pass at **every** commit.
  - No drive-by reformatting.
  - Every phase of a plan makes at least one commit.
  - A commit that fixes a finding names its ID, e.g. `fix(F1): ...`.
  - End commit messages with the attribution line the harness provides.
- **Keep docs in sync.** The output of `kiwix-zim-updater.sh -h` and the usage block in `README.md` must match byte for byte. From the repository root, this runs `-h` from a scratch directory and compares the two:

  ```sh
  diff <(cd "$(mktemp -d)" && bash "$OLDPWD/kiwix-zim-updater.sh" -h) <(awk '/^## Usage$/{u=1;next} u && /^```text$/{p=1;next} p && /^```$/{exit} p' README.md)
  ```

  The exit-code table below and the one in `README.md` must also agree.

## Bash style

- Target Bash 4 or later with GNU userland. The script relies on `grep -P`, GNU `date -d`, `numfmt` and `flock`.
- Quote every expansion. Initialise every global near the top of the script, so that no value leaks in from the environment.
- **Sourcing must stay side-effect free.** `test/unit.bats` sources the script, which is safe only because all work happens in `main()`, behind the `[[ "${BASH_SOURCE[0]}" == "$0" ]]` source guard at the bottom. Keep it that way: at top level, put nothing but function definitions and default assignments. No output, no commands with side effects, no `cd`, no `shopt`/`set` changes and no file or network access outside a function.
- **Do not add a blanket `set -e`.** The script relies on `[[ ... ]] && ...` chains, which would abort it. Check exit statuses explicitly instead.
- For pipelines like `wget ... | tee`, check `${PIPESTATUS[0]}`. The status of the pipeline itself is `tee`'s.
- Write files that other runs read, such as the index or checksums, to a temporary file first and `mv` it into place.
- Every inline `# shellcheck disable=SCxxxx` needs a comment that says why.

## Exit-code contract

| Code | Meaning |
|---|---|
| 0 | Success, including "nothing to update". |
| 1 | Runtime error, such as a network or parse failure, a missing dependency, no ZIMs found in the ZIM directory or any failed download (including a size or checksum mismatch). With `-f`, also any ZIM that could not be verified, or that was found corrupt and kept (a ZIM that is not in the catalog and has no cached `.sha256` is outside what `-f` covers: it is reported as not checked and does not change the exit code). Also `-d` on a ZIM directory that is not writable (the run falls back to dry-run), and a `--library` file that could not be written. |
| 2 | Usage error: a bad option or value, more than one ZIM directory, a missing or invalid ZIM directory, or `-c`/`-f` together with `-t`. |
| 75 | Another instance is already running on this ZIM directory. |

Any change to this contract must update this table, the README and the tests together.
