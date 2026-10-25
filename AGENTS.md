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
| `test/helpers/common.bash` | Shared setup. It creates a sandbox, copies the script there and prepends the stub `PATH`. |
| `test/helpers/bin/` | Stubs for `wget`, `clear` and `git`, so tests never touch the network or the real repository. |
| `test/fixtures/` | A fake catalog, `.meta4` files and payloads served by the `wget` stub. |
| `test/libs/` | Pinned git submodules for bats-core, bats-support and bats-assert. |
| `Makefile` | `make test`, `make lint`. |
| `.github/workflows/ci.yml` | CI runs lint and tests on every push and pull request. |

Set up and run everything with:

```sh
git submodule update --init --recursive
make lint test
```

## Hard rules

1. **Never run the script outside the test sandbox.** That rules out real ZIM directories, `-d`/`--disable-dry-run` and the repository working tree as the current directory. The script writes `download.log` and `kiwix-index` into the current directory. Its self-update can run `git stash` and `git pull` on the clone it lives in.
2. **Never contact kiwix.org from tests.** All network access goes through the `wget` stub in `test/helpers/bin/`. The one exception is a manual, read-only, dry-run check that a human explicitly asks for.
3. **Dry-run is sacred.** While `DEBUG=1` (the default, i.e. no `-d`), nothing inside the ZIM directory may be created, modified or deleted. That includes `.sha256` files, lock files and torrents. Writing `download.log` and `kiwix-index` in the current directory is allowed.
4. **No unverified deletes.** Every code path that runs `rm` on a ZIM must be preceded by either:
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
  - Each commit message names its finding ID, e.g. `fix(F1): ...`.
  - End commit messages with the attribution line the harness provides.
- **Keep fixes cherry-pickable.** Upstream may want individual fixes, so a fix must not depend on an unrelated refactor.
- **Keep docs in sync.** Run `./kiwix-zim-updater.sh -h`. Its output and the usage block in `README.md` must match.

## Bash style

- Target Bash 4 or later with GNU userland. The script relies on `grep -P`, GNU `date -d`, `numfmt` and `flock`.
- Quote every expansion. Initialise every global near the top of the script, so that no value leaks in from the environment.
- **Do not add a blanket `set -e`.** The script relies on `[[ ... ]] && ...` chains, which would abort it. Check exit statuses explicitly instead.
- For pipelines like `wget ... | tee`, check `${PIPESTATUS[0]}`. The status of the pipeline itself is `tee`'s.
- Write files that other runs read, such as the index or checksums, to a temporary file first and `mv` it into place.
- Every inline `# shellcheck disable=SCxxxx` needs a comment that says why.

## Exit-code contract

| Code | Meaning |
|---|---|
| 0 | Success, including "nothing to update". |
| 1 | Runtime error, such as a network or parse failure, a missing dependency or a failed download. |
| 2 | Usage error: a bad option or value, or a missing or invalid ZIM directory. |
| 75 | Another instance is already running on this ZIM directory. |

Any change to this contract must update this table, the README and the tests together.
