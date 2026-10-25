# kiwix-zim-updater

Keeps a local library of Kiwix ZIM files up to date. It compares every ZIM in a directory with the online Kiwix catalog by the date in its file name, downloads newer versions, and removes the old ones once the new ones are verified. It is built to run unattended (cron or Docker): a failed run never costs you a ZIM, so your library stays usable offline.

This is a fork of [jojo2357/kiwix-zim-updater](https://github.com/jojo2357/kiwix-zim-updater); see [Changes in this fork](#changes-in-this-fork).

## Quick start

```shell
git clone https://github.com/philon-/kiwix-zim-updater.git
cd /var/lib/kiwix          # download.log and the catalog cache are written here
/path/to/kiwix-zim-updater/kiwix-zim-updater.sh /srv/kiwix/zims/          # dry-run: shows what it would do
/path/to/kiwix-zim-updater/kiwix-zim-updater.sh -d -c /srv/kiwix/zims/    # really update, with checksums
```

The script runs as a **dry-run unless you pass `-d`**: it then changes nothing in the ZIM directory. Only ZIMs that keep their original `download.kiwix.org` file names (`<name>_<YYYY-MM>.zim`) are recognised.

## What keeps your library safe

- **Nothing unverified replaces a ZIM.** A new version is downloaded as `<name>.zim.part` and only renamed to `.zim` once its size matches the published metadata (and its sha256, with `-c`). Only then is the old version removed (`-p` keeps it).
- **Failures leave everything as it was.** A failed or interrupted download stays a `.part` file and is resumed by the next run. During an internet outage a run exits 1 without touching the ZIM directory.
- **The disk does not fill up.** A download is skipped when it would leave less than `--min-free` (default 1 GiB) free. Requests time out instead of hanging.
- **One run per ZIM directory** at a time (`flock`); a second one exits 75.
- **`-f` checks the library** against the published checksums and replaces a corrupt current ZIM only once its replacement is verified. It never deletes a ZIM it cannot replace. A ZIM it cannot verify makes the run exit 1; one that is not in the catalog and has no cached `.sha256` is reported as not checked.
- **Leftovers are reported, not deleted.** `.part` files that can no longer be used are listed at the end of a run; `--clean-partials` removes them.

## Running from cron

```crontab
MAILTO=you@example.org
0 3 * * * cd /var/lib/kiwix && /opt/kiwix-zim-updater/kiwix-zim-updater.sh -d -c /srv/kiwix/zims/ >/dev/null 2>&1 || echo "kiwix-zim-updater exited with $?, see /var/lib/kiwix/download.log"
```

`download.log` (watch it with `tail -f`) and `kiwix-index` (the catalog, cached for a day) are written to the directory the script is run from.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, including "nothing to update". |
| 1 | Runtime error: network or parse failure, missing dependency, no ZIMs found, a failed download (including a size or checksum mismatch), with `-f` a ZIM that could not be verified or was found corrupt and kept, `-d` on a ZIM directory that is not writable, or a library file that could not be written. |
| 2 | Usage error: bad option or value, missing or invalid ZIM directory, or `-c`/`-f` with `-t`. |
| 75 | Another instance is already running on the same ZIM directory. |

## Keeping kiwix-serve up to date

kiwix-serve started with `*.zim` keeps serving the files it opened at start-up. Let the updater maintain a library file instead, and kiwix-serve picks up every update within seconds, without a restart:

```shell
kiwix-zim-updater.sh -d -c --library /srv/kiwix/zims/library.xml /srv/kiwix/zims/
kiwix-serve --library --monitorLibrary /srv/kiwix/zims/library.xml
```

The library lists the finished ZIMs in the directory: a new download only appears once it is verified, and before the old version is removed, while unfinished `.part` files never do. ZIMs that were already there are listed as they are, without a fresh integrity check; run `-f` to verify those. Keep the library in the ZIM directory (its paths are relative to it), and don't let other tools replace the file: kiwix-serve 3.8 stops watching a library file that was replaced by a rename. Needs `kiwix-manage` from kiwix-tools. Tested with kiwix-tools 3.7.0 (Debian 13) and the official `ghcr.io/kiwix/kiwix-serve` image (3.8.2).

## Running with Docker

```shell
cp compose.example.yaml compose.yaml        # set your ZIM directory; every variable is documented there
PUID=$(stat -c %u /srv/kiwix/zims) PGID=$(stat -c %g /srv/kiwix/zims) docker compose up -d --build
docker compose logs -f kiwix-zim-updater
```

The container runs the updater immediately and then every `RUN_INTERVAL` (default `24h`). Its defaults are dry-run (`DRY_RUN=true`), checksums (`CHECKSUM=true`) and `--clean-partials`; set `DRY_RUN: "false"` once the log looks right. `/data` is the ZIM directory (mount it: without a mount every run finds an empty volume and fails with "No ZIMs found", exit 1), `/state` holds the log, the catalog cache and the last run's status. The container is unhealthy while the last run failed, which is how an outage shows up; nothing in `/data` is touched. If it cannot record a run's status in `/state`, it stops with exit 1 rather than report a stale state. `docker stop` ends a run cleanly, and an interrupted download resumes next time. The compose example also sets `LIBRARY_XML` and contains an optional kiwix-serve service that serves the same directory.

One-off runs: `docker run --rm kiwix-zim-updater -h`. Arguments are passed to the script unchanged.

## Requirements

Bash 4+, GNU coreutils, `flock` (util-linux), `wget` 1.x or GNU Wget2, and `grep` with `-P`. `git` only for `-U`; `kiwix-manage` (kiwix-tools) and `cmp` only for `--library`. The script checks these at startup.

To update a clone: `git pull --ff-only`, or pass `-U` to let the script fast-forward itself before it runs (it refuses when the clone has local changes).

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
    --library <file>           Keeps a kiwix library XML file listing the finished ZIMs up to date, for
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

`-v` prints the version.

## Development

```shell
git submodule update --init --recursive
make lint test          # ShellCheck and the bats test suites
make docker-build       # build the image (podman or docker)
make docker-test        # build the image and smoke-test it offline
make library-test       # --library end to end with real ZIMs and the official kiwix-serve
```

The tests never touch the network or your ZIMs: they run in a sandbox with stubs for `wget` and friends. Read [AGENTS.md](./AGENTS.md) before changing anything.

## Changes in this fork

Compared with upstream: verified downloads staged in `.part` files that are resumed after interruptions; a safer `-f` that never deletes what it cannot replace; meaningful exit codes; input validation; a free-space reserve and network timeouts; GNU Wget2 support; one instance per ZIM directory; a kiwix library file for kiwix-serve (`--library`); a Docker image; self-update only on request (`-U`); and a working `-S`.
