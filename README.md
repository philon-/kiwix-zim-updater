# kiwix-zim-updater.sh

A script to check `download.kiwix.org` for updates to your local ZIM library.

Just pass this script your ZIM directory and away it goes. *(see [Usage](#usage) below)*

Tested on Debian 13, and should work out of the box on most Debian systems, but I have not tested that.

This is a fork of [jojo2357/kiwix-zim-updater](https://github.com/jojo2357/kiwix-zim-updater) that focuses on safe unattended use. See [Changes in this fork](#changes-in-this-fork) for what behaves differently.

## What It Does

I wanted an easy way to ensure my ZIM library was kept updated without actually needing to check every ZIM individually. I looked for a tool to do this, but didn't find anything... so I put on my amateur BASH hat and made one.

Some people run this script via a scheduled cron job where they store their ZIM library and host a Kiwix server. <!-- After it's complete, I follow it up with an automated call to update my `library.xml` for the Kiwix server (Note: this part is not provided via this script). This keeps my ZIM library and Kiwix server updated.-->

It works for me. Your mileage may vary...no warranty, see [the license](./LICENSE) for more info

This script will parse a list of all ZIM(s) found in the ZIM directory passed to it. It then checks each ZIM against the online Kiwix catalog via the file name Year-Month part.

Any ZIMs with newer versions online will then be replaced by default. There is an option to verify the downloaded checksums automatically, and options to set the maximum and minimum ZIM size to download. Although default behavior is to purge the old ZIM once the new ZIM passes inspection, purging can be disabled if you would like to keep an archive of old ZIMs.

```text
Note: Due to the nature of ZIM sizes and internet connection speeds,
      you should expect the download process to take a while.

      This script will output the download progress bar during the
      download process just so you can see that the script hasn't
      frozen or locked up.

      Download status is also logged in real-time for monitoring from
      outside this script.
```

### Dry-run by default

For data safety reasons, this script runs as a "dry-run" by default. It will not download or purge anything, however, it will "go through the motions" and output what it would have actually done, allowing you to review the "effects" before committing to them.

Once you are good with the dry-run results and wish to commit to them, simply re-run the script like you did the first time, but this time add the dry-run override flag (`-d`).

A dry-run does not create, change or delete anything inside the ZIM directory: no ZIMs, no `.sha256` files, no `.torrent` files and no download markers. It still:

- fetches the online catalog and the `.meta4` metadata of the ZIMs it would download or verify;
- writes `download.log` and `kiwix-index` in the directory you run the script from (see below);
- with `-f`, reads and hashes your ZIMs, which can take a long time on a large library.

If the ZIM directory is not writable, the script says so and carries on as a dry-run. When `-d` was given, that run then exits 1, so cron notices that nothing was changed.

```text
Bonus: A dry-run/simulation run is not required. If you like to
       live dangerously, feel free to just call the script with
       the override flag right from the start.

       It's your ZIM library... not mine.
```

### `download.log` and `kiwix-index`

Both files are written to the **current directory**, i.e. the directory you run the script from, not the ZIM directory and not the directory the script lives in.

`download.log` exists for the following reasons:

1. History of what was done. Just good to have.
2. Because downloads can take a really long time, if you were to run this script in the background, you'd have no real way of monitoring the status of any downloads it may be running... `download.log` can be monitored for real-time status of any downloads taking place. You could use a very simple `tail -f download.log` to watch those download stats in real-time from outside of the script.

`kiwix-index` is a cache of the online catalog. It is reused for one day; `-g` fetches a fresh catalog anyway. The cache is only replaced after a catalog was fetched and parsed successfully, so a failed fetch never leaves an empty cache behind.

## Safety behaviour

- **The old ZIM is purged only after its replacement is verified.** The download must finish without a `wget` error, and the size of the new file must match the size published in the ZIM's `.meta4` metadata. With `-c`, its sha256 must match as well. If the metadata cannot be fetched, the new file cannot be verified and the old ZIM is kept. With `-p` the old ZIM is never purged.
- **A failed download never costs you the old ZIM.** The other ZIMs are still processed, and the run exits 1.
- **Downloads are staged in a `.part` file.** A new ZIM is downloaded as `<name>.zim.part` and only renamed to `<name>.zim` once it passed the size check (and the sha256 with `-c`), so Kiwix, and this script, never see an unfinished or unverified file under a `.zim` name. If the download fails or is interrupted, the `.part` file is kept, and the next run that updates that ZIM continues it (`wget -c`) instead of starting over. A complete `.part` file, for example after a run was killed while hashing it, is verified and renamed without being downloaded again. A `.part` file that fails its checksum is deleted, and one that is larger than published is started over. A `.part` file that no run can use any more, because its release left the catalog, or because `-f` has just verified its finished ZIM as good, is listed at the end of the run. Delete it yourself, or run with `--clean-partials` to have the script delete such files. Nothing else is ever deleted by that option: a `.part` file that a later run can still resume is kept, for example one held back by `-n`/`-x`, or the replacement of a corrupt ZIM that the next `-f` run continues. `--clean-partials` treats every `*.zim.part` file in the ZIM directory as its own, so don't let a browser or another download tool save into the ZIM directory while you use it.
- **Leftovers of older versions.** Older versions of this script downloaded straight into the ZIM's name and marked unfinished files with a `.~lock.<name>` file. Such a file next to an older version of the same ZIM is turned into a `.part` file and resumed. A lone one, with no other version of the ZIM next to it, is finished in place as before. The cleanup never deletes a file that has such a marker; it only removes a marker whose file is gone.
- **`-f` never deletes a ZIM it cannot replace.** With `-d`, `-f` replaces a ZIM only when it is the version currently in the catalog, it failed the size or sha256 check against the published metadata, and `-p` is not given. The replacement is downloaded into a `.part` file, and the corrupt ZIM stays in place until the new file is verified and renamed over it. A ZIM that is outdated or has no catalog entry is only checked against its own checksum (a cached `.sha256` next to it, or for an outdated ZIM the checksum still published online) and is never deleted. A ZIM that fails its check and is kept, or that cannot be verified because its metadata or checksum is unavailable, is reported, and the run exits 1. A ZIM with no checksum anywhere to check against is skipped.
- **The disk never fills up.** Before a download starts, the script checks that the file system holding the ZIM directory keeps at least `--min-free` (default 1 GiB) free after it. Otherwise the download is skipped, the old ZIM is kept and the run exits 1. A download whose size cannot be verified, because the metadata is unavailable, is not started at all.
- **A stalled connection cannot hang a run.** Every request has a 30 second connect timeout, a 5 minute read timeout and at most 3 tries. When a download gives up, it stays a `.part` file and the next run continues it.
- **An internet outage changes nothing locally.** Without the catalog the run stops with exit 1 before it touches the ZIM directory. Without the metadata no download starts and nothing is purged. Your ZIMs stay exactly as they are and keep working offline; the next run after the outage picks up where it left off.
- **One instance per ZIM directory.** The script takes an exclusive `flock` on the ZIM directory itself before it fetches the catalog. A second run on the same directory exits 75 straight away. No lock file is created, so this also works on a read-only directory. Runs on different ZIM directories do not block each other.
- **Torrents (`-t`)** only download the `.torrent` file next to the old ZIM. The old ZIM is kept; downloading the torrent's content is up to your torrent client.
- **Checksum files.** For each ZIM it downloads or verifies, the script stores the published sha256 as `<ZIM name>.sha256` next to the ZIM, so that `-f` can check the library later without the metadata servers: when the metadata cannot be fetched, `-f` verifies against the stored checksum instead. The catalog is still needed, so a fully offline `-f` run only works while the cached `kiwix-index` is less than a day old. `-S` turns writing these files off. A checksum file is never written in a dry-run, for a failed download, or with an empty or malformed hash.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, including "nothing to update". |
| 1 | Runtime error: a network or parse failure (catalog or metadata), a missing dependency, no ZIMs found in the ZIM directory, any failed download (including a size or checksum mismatch), with `-f`, any ZIM that could not be verified or was found corrupt and kept, and `-d` on a ZIM directory that is not writable (the run falls back to dry-run). |
| 2 | Usage error: an unknown option, a missing or invalid option value, more than one ZIM directory, a missing or invalid ZIM directory, or `-c`/`-f` together with `-t`. The message goes to stderr. |
| 75 | Another instance is already running on the same ZIM directory. |

An invalid `-l` country code is not an error: the script warns on stderr and uses Kiwix's default mirror selection.

### Running from cron

The script only clears the screen when its output is a terminal, so cron mails and redirected logs stay clean of `TERM` errors. Make cron tell you when something went wrong, either by letting it mail you the output (`MAILTO`) or by checking `$?`. For example, to update every night at 03:00 and only get mail when a run fails:

```crontab
MAILTO=you@example.org
0 3 * * * cd /var/lib/kiwix && /opt/kiwix-zim-updater/kiwix-zim-updater.sh -d /srv/kiwix/zims/ >/dev/null 2>&1 || echo "kiwix-zim-updater exited with $?, see /var/lib/kiwix/download.log"
```

Here `download.log` and `kiwix-index` end up in `/var/lib/kiwix`. Exit code 75 only means that the previous run is still busy; you may want to ignore it.

For unattended use, consider adding `-c`: without it, a replacement is verified by its size only before the old ZIM is purged; with it, also by its sha256. If the disk holding the ZIMs is shared with other services, raise `--min-free` so updates always leave them room. During an internet outage every run simply exits 1 and changes nothing, so it is safe to keep the cron job running.

## Keeping kiwix-serve up to date

kiwix-serve started with a list of ZIM files keeps serving the files it opened at start-up: after an update it goes on serving the replaced file until it is restarted. Instead, let the updater maintain a library file and let kiwix-serve watch it:

```shell
kiwix-zim-updater.sh -d -c --library /srv/kiwix/zims/library.xml /srv/kiwix/zims/
kiwix-serve --library --monitorLibrary /srv/kiwix/zims/library.xml
```

With `--library <file>`, every run that changes the set of verified ZIMs rewrites the library file (with `kiwix-manage` from kiwix-tools), and kiwix-serve reloads it within a few seconds, without a restart:

- A new ZIM is listed as soon as it is verified and renamed into place, before the old version is purged, so a title is never missing.
- Only verified ZIMs are listed. Unfinished `.part` files and files behind an old-style `.~lock.` marker never are, and a ZIM that `kiwix-manage` cannot read is reported and left out.
- The file is written in place and only when its content changes. kiwix-serve 3.8 stops noticing changes once its library file is replaced by a rename, so don't let other tools replace it either. If kiwix-serve happens to read a half-written file, it keeps serving the books it has and reloads once the write is done.
- If no ZIM at all can be added, the existing library is kept and the run exits 1. A dry-run, a failed download and an internet outage leave the library untouched.
- Paths in the library are relative to the library file. Put it in the ZIM directory so that it stays valid wherever the directory is mounted (for example in another container).

Tested with kiwix-tools 3.7.0 (Debian 13) and the official `ghcr.io/kiwix/kiwix-serve` image (kiwix-tools 3.8.2).

## Running with Docker

The repository includes a `Dockerfile` for unattended use with Docker or Podman. The image is based on `debian:trixie-slim` and holds only the script and the tools it needs. It runs as an unprivileged user (uid/gid 1000) under `tini`. The image contains no git and never updates itself: to update, build or pull a new image.

### Build

```shell
docker build -t kiwix-zim-updater .
podman build --format docker -t kiwix-zim-updater .   # --format docker keeps the HEALTHCHECK
```

### Run with Compose

Copy [`compose.example.yaml`](./compose.example.yaml) to `compose.yaml`, set the path of your ZIM directory and the variables, then start it:

```shell
cp compose.example.yaml compose.yaml
PUID=$(stat -c %u /srv/kiwix/zims) PGID=$(stat -c %g /srv/kiwix/zims) docker compose up -d --build
docker compose logs -f kiwix-zim-updater
```

Without arguments, the container runs the updater right away and then again every `RUN_INTERVAL` (default `24h`, counted from the end of a run). It prints one line when a run starts and one when it ends, and records the exit code and UTC time of each finished run in `/state/last-run`, for example `exit=0 time=2026-10-25T12:00:00Z`. Exit 75 (another instance is busy with the same ZIM directory) is not treated as an error; the next run tries again.

**Start with a dry-run.** The example starts with `DRY_RUN: "true"`, the default, so the first runs only report what they would download and purge, and change nothing in the ZIM directory. Read the log (`docker compose logs` or `download.log` in the state volume), then set `DRY_RUN: "false"` and run `docker compose up -d` again.

### One-off runs

Arguments after the image name are passed to the script unchanged, and the container exits with the script's exit code. The environment variables below are then ignored and no schedule runs:

```shell
docker run --rm kiwix-zim-updater -h
docker run --rm --user "$(id -u):$(id -g)" -v /srv/kiwix/zims:/data -v kiwix-state:/state kiwix-zim-updater -c /data
```

`-U` (self-update) is refused in the container.

### Environment variables

Booleans accept `true`, `false`, `1`, `0`, `yes` and `no` in any case; an empty value means the default. An invalid value makes the container exit 2 with a message on stderr, before anything runs.

| Variable | Default | Maps to | Notes |
|---|---|---|---|
| `DRY_RUN` | `true` | `-d` when `false` | Leave on until a dry-run log looked right. |
| `RUN_INTERVAL` | `24h` | sleep between runs | `<number>[s\|m\|h\|d]`. `once` or `0` runs once and exits with the script's exit code. |
| `CHECKSUM` | `true` | `-c` | Web downloads only; never passed with `DOWNLOAD_METHOD=torrent`. |
| `CLEAN_PARTIALS` | `true` | `--clean-partials` | Deletes only `.part` files that no run can use any more. |
| `SKIP_PURGE` | `false` | `-p` | Keep replaced ZIMs. |
| `VERIFY_LIBRARY` | `false` | `-f` | Not with `DOWNLOAD_METHOD=torrent` (exit 2). |
| `NO_SHA` | `false` | `-S` | Do not write `.sha256` files. |
| `MIN_SIZE`, `MAX_SIZE` | empty | `-n <v>`, `-x <v>` | Sizes like `500M` or `10G`. |
| `MIN_FREE_SPACE` | empty | `--min-free <v>` | Free space to keep in the ZIM directory after a download; empty uses the script's default (1Gi). |
| `LIBRARY_XML` | empty | `--library <v>` | Library file for `kiwix-serve --monitorLibrary`, e.g. `/data/library.xml` (the compose example sets this). Empty: none. |
| `COUNTRY` | empty | `-l <v>` | Two-letter mirror country code, e.g. `DE`. |
| `DOWNLOAD_METHOD` | `web` | `-w` or `-t` | `web` or `torrent`. |
| `FORCE_FETCH_INDEX` | `false` | `-g` | Fetch the catalog on every run. |
| `EXTRA_ARGS` | empty | appended | Advanced: more script options, split on whitespace. `-U` is refused. |
| `ZIM_DIR` | `/data` | the ZIM directory | Path inside the container. |
| `STATE_DIR` | `/state` | working directory | `download.log`, `kiwix-index` and `last-run` land here. |

With the defaults, each run calls `kiwix-zim-updater.sh -w -c --clean-partials /data`, a dry-run.

### Volumes and permissions

- `/data` is the ZIM directory. Mount it read-write for downloads and purges. A read-only mount works for dry-runs; with `DRY_RUN=false` the script then falls back to a dry-run and the run exits 1.
- `/state` is the working directory: `download.log`, the `kiwix-index` catalog cache and `last-run`. Use a named volume or a bind mount, so that the log and the cache survive a new container. None of these files is ever written to `/data`.
- The container must run as a user that can write both. Set `user:` in Compose (the example uses `${PUID:-1000}:${PGID:-1000}`) or `--user` with `docker run` to the owner of the ZIM directory. A new named volume is owned by uid 1000; with a different user, use a bind mount owned by that user for `/state`.

### Health check

The image's `HEALTHCHECK` runs `healthcheck.sh` every 5 minutes. The container is healthy while no run has finished yet, and when the last run exited 0 or 75 or was interrupted by a stop. It is unhealthy when the last run failed, so a failure shows up in `docker ps` and in your monitoring. It becomes healthy again after the next successful run. Being unhealthy changes nothing in the ZIM directory.

### Stopping safely

`docker stop` (or `docker compose stop`) sends SIGTERM. The entrypoint forwards it to the running script and its `wget`, waits for them, records the interrupted run in `last-run` and exits. An interrupted download stays a `<name>.zim.part` file and the next run resumes it; the old ZIM stays in place until its replacement is verified. A stop during the sleep between runs exits straight away. The example sets `stop_grace_period: 2m`; avoid `docker kill`, which gives the script no chance to finish its log.

### Serving the library with kiwix-serve

`compose.example.yaml` sets `LIBRARY_XML: "/data/library.xml"` and contains a commented-out `kiwix-serve` service (`ghcr.io/kiwix/kiwix-serve`) that mounts the same ZIM directory read-only and runs `--library --monitorLibrary /data/library.xml`. kiwix-serve then picks up every update within seconds, without a restart (see [Keeping kiwix-serve up to date](#keeping-kiwix-serve-up-to-date)). Until the updater's first run with `DRY_RUN=false` has written the library file, kiwix-serve exits at start-up and `restart: unless-stopped` keeps restarting it; that is expected.

### During an internet outage

When the catalog or the downloads cannot be reached, the run fails with exit 1, `last-run` records it and the container becomes unhealthy. Nothing in `/data` is touched: a ZIM is only replaced after its new version was downloaded and verified, so the existing ZIMs stay complete and usable offline, and kiwix-serve keeps serving them. A download cut off half-way stays a `.part` file and is resumed once the connection is back. The container keeps running and tries again after `RUN_INTERVAL`.

## Limitations

- This script relies heavily on `grep`'s `-P` flag for lookarounds and the matcher reset, `\K`. This may cause compatibility problems on macOS.
- This script is only for ZIM(s) hosted by `download.kiwix.org` due to the file naming standard they use. If you have self-made ZIM(s) or ZIM(s) downloaded from somewhere else, they most likely do not use the same naming standards and will not be processed by this script.
- If you have ZIM(s) from `download.kiwix.org`, but you have changed their file names, this script will treat them like the previous limitation explains.
- The new ZIM is downloaded before the old one is purged, so you need enough free space for both.
- This script does not attempt to update any `library.xml` that may or may not exist/be needed for your install/setup of Kiwix. If needed, you'll need to handle this part on your own.

## Requirements

This script does not need root, however it does need the same rights as your ZIM directory or it won't be able to download and/or purge ZIMs.

- Bash 4 or later.
- GNU coreutils: `numfmt`, `stat`, `du`, `df`, `sha256sum`, `timeout` (and GNU `date`).
- `flock` from util-linux.
- `wget` 1.x or GNU Wget2. Wget2 is supported: it follows metalinks by default, so the script passes `--no-metalink` to it for its metadata requests and downloads.
- `grep` with `-P` (PCRE) support.
- `git`, only if you use the self-update (`-U`).
- `kiwix-manage` (from kiwix-tools) and `cmp` (from diffutils), only if you use `--library`.

The script checks for these tools at startup and exits 1, naming every missing one, before it does any work.

## Install

The recommended way to install is a git clone, which also makes updating easy:

```shell
git clone https://github.com/philon-/kiwix-zim-updater.git
```

You can also just download `kiwix-zim-updater.sh` on its own. It works the same way, except that `-U` has nothing to update.

## Updating

The script no longer updates itself unless you ask it to. Either update the clone yourself:

```shell
git -C /path/to/kiwix-zim-updater pull --ff-only
```

or pass `-U` (`--self-update`) to let the script do it before it runs. `-U`:

- only acts in a git clone that is on the `main` branch;
- never stashes or overwrites anything: it refuses to update when the working tree has local changes;
- only fast-forwards (`git pull --ff-only`), and reports when fetching the update fails;
- after updating, runs the new version once with the same arguments.

Without `-U` the script runs no git commands at all. `-u` (`--skip-update`) is still accepted so that existing cron lines keep working, but it no longer does anything.

## Usage

```text
Usage: ./kiwix-zim-updater.sh <options> /full/path/

    /full/path/                Full path to ZIM directory

Universal Options:
    -h, --help                 Show this usage and exit.
    -U, --self-update          Updates this script from its git clone before running (off by default).
    -u, --skip-update          Accepted for compatibility; self-update is now off unless -U is given.
    -g, --get-index            Forces using remote index rather than cached index. Cache auto clears after one day
    -n <size>, --min-size      Minimum ZIM Size to be downloaded.
                               Specify units include M Mi G Gi, etc. See `man numfmt`
    -x <size>, --max-size      Maximum ZIM Size to be downloaded.
                               Specify units include M Mi G Gi, etc. See `man numfmt`
    --min-free <size>          Free space to keep in the ZIM directory after a download (default 1Gi, 0 disables).
                               A download that would leave less is skipped and the old ZIM kept.
    --library <file>           Keeps a kiwix library XML file listing the verified ZIMs up to date, for
                               kiwix-serve --library --monitorLibrary. Best placed in the ZIM directory.
    -S, --no-sha               Disables saving the zim checksum for future reference. Does not delete present checksums.
                               
Action Method Options:
    -w, --web                  Downloads zims over http(s).
    -t, --torrent              Downloads `.torrent` files. REQUIRES ADDITIONAL SOFTWARE TO EXECUTE DOWNLOAD.
    
    -f, --verify-library       Verifies that the entire library has the correct checksums as found online.
                               Expected behavior is to create sha256 files during a normal run so this option can be used at a later date without internet.
                               Use -S to stop new .sha256 files from being written.

Web Download Options:
    -c, --calculate-checksum   Verifies that the downloaded files were not corrupted, but can take a while for large downloads.
    -p, --skip-purge           Skips purging any replaced ZIMs.
    -l <location>, --location  Country Code to prefer mirrors from
    --clean-partials           Deletes unfinished downloads (.part files) whose release left the catalog, or
                               whose finished ZIM -f has just verified as good.
    -d, --disable-dry-run      Dry-Run Override.
                               *** Caution ***

```

`-v` (`--version`) prints the script version and exits. Options and the ZIM directory can be given in any order. `-l` expects a two-letter upper-case country code, such as `DE`.

## Development and tests

The tests use [bats-core](https://github.com/bats-core/bats-core), pinned as git submodules under `test/libs/`:

```shell
git submodule update --init --recursive
make test    # run all bats suites in test/
make lint    # ShellCheck the script and the test harness
```

`make lint` uses `shellcheck` when it is installed and otherwise runs the pinned `koalaman/shellcheck` container image with `podman`. CI (GitHub Actions) runs `make lint` and `make test` on every push and pull request.

`make docker-test` builds the container image with `podman` (or `docker`; set `CONTAINER_ENGINE` to choose) and smoke-tests it offline with the stubs below, with no network in the containers. CI runs it with Docker. It is not part of `make test`.

The tests never touch the network, your ZIMs or this repository. Each test copies the script into its own temporary sandbox outside the repository, runs it from a temporary directory against a temporary ZIM directory, and puts stubs from `test/helpers/bin/` first on `PATH`:

- `wget` serves a fake catalog, `.meta4` files and small payload "ZIMs" from `test/fixtures/`, and can simulate failed, short and corrupt downloads, failed metadata requests and Wget2.
- `git` fails loudly unless a test explicitly allows it. Tests of `-U` use throwaway repositories inside the sandbox.
- `clear` does nothing.

`test/fixtures/build.sh` regenerates the fixtures. Read [AGENTS.md](./AGENTS.md) before changing anything: it holds the safety rules, the workflow and the exit-code contract for this repository.

## Changes in this fork

Compared with upstream [jojo2357/kiwix-zim-updater](https://github.com/jojo2357/kiwix-zim-updater):

- **Self-update is opt-in** with `-U`. It never stashes local changes, only fast-forwards and re-runs once. `-u` is accepted but does nothing.
- **Exit codes** 0, 1, 2 and 75 (see [Exit codes](#exit-codes)). Previously almost every error exited 0.
- **Input validation.** Unknown options, missing or invalid `-n`/`-x`/`-l` values and extra arguments are rejected with exit 2 instead of being ignored. `-c`/`-f` with `-t` now really aborts.
- **Safer purge.** The download's exit status and size are verified before the old ZIM is purged, also without `-c`. A failed checksum no longer leaves an empty file that hides the old ZIM.
- **Safer `-f`.** Outdated ZIMs and ZIMs without a catalog entry are checked against their own checksum and never deleted. Missing metadata never leads to a delete. A dry-run `-f` writes nothing.
- **Downloads are staged** in `.part` files and only renamed to `.zim` once verified, so Kiwix never sees an unfinished file. `--clean-partials` deletes `.part` files that can no longer be used. Interrupted downloads are resumed on the next run instead of being deleted and started over, and `-f` replaces a corrupt ZIM only once its replacement is verified.
- **GNU Wget2 support.**
- **One instance per ZIM directory**, enforced with `flock`.
- **Unattended safety.** A free-space reserve (`--min-free`, default 1 GiB) keeps downloads from filling the disk, network requests have timeouts and a retry limit, and no download starts when its size cannot be verified.
- **`-S` works.** It used to be accepted but had no effect.
- **`download.log` and `kiwix-index`** always stay in the directory you run the script from.
- **ZIM listing.** Names with spaces and upper-case `.ZIM` extensions are handled, directories named `*.zim` are ignored, and a file whose name merely ends in a catalog name is no longer mistaken for that ZIM. Exported environment variables such as `SKIP_PURGE` no longer change the script's behaviour.
- **Startup checks** for all required tools.
- **The `kiwix-zim.sh` legacy name is dropped.** Running the script under that name no longer prints a deprecation warning or exits 2.
