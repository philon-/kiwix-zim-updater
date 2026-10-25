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

If the ZIM directory is not writable, the script says so and carries on as a dry-run even when `-d` is given.

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
- **Interrupted downloads are resumed.** While a download is running, the script keeps a `.~lock.<new ZIM name>` marker next to it in the ZIM directory. If the download fails or is interrupted, the partial file and the marker are kept, and the next run continues the download (`wget -c`) instead of starting over. A download that turned out larger than expected, or that failed its checksum, cannot be resumed and is cleaned up.
- **`-f` never deletes a ZIM it cannot replace.** With `-d`, `-f` deletes a ZIM only when it is the version currently in the catalog, it failed the size or sha256 check against the published metadata, and `-p` is not given; it is then downloaded again. A ZIM that is outdated or has no catalog entry is only checked against its own checksum (a cached `.sha256` next to it, or for an outdated ZIM the checksum still published online) and is never deleted. A ZIM that fails its check and is kept, or that cannot be verified because its metadata or checksum is unavailable, is reported, and the run exits 1. A ZIM with no checksum anywhere to check against is skipped.
- **One instance per ZIM directory.** The script takes an exclusive `flock` on the ZIM directory itself before it fetches the catalog. A second run on the same directory exits 75 straight away. No lock file is created, so this also works on a read-only directory. Runs on different ZIM directories do not block each other.
- **Torrents (`-t`)** only download the `.torrent` file next to the old ZIM. The old ZIM is kept; downloading the torrent's content is up to your torrent client.
- **Checksum files.** For each ZIM it downloads or verifies, the script stores the published sha256 as `<ZIM name>.sha256` next to the ZIM, so that `-f` can check the library later without internet. `-S` turns that off. A checksum file is never written in a dry-run, for a failed download, or with an empty or malformed hash.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, including "nothing to update". |
| 1 | Runtime error: a network or parse failure (catalog or metadata), a missing dependency, no ZIMs found in the ZIM directory, any failed download (including a size or checksum mismatch), and, with `-f`, any ZIM that could not be verified or was found corrupt and kept. |
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

## Limitations

- This script relies heavily on `grep`'s `-P` flag for lookarounds and the matcher reset, `\K`. This may cause compatibility problems on macOS.
- This script is only for ZIM(s) hosted by `download.kiwix.org` due to the file naming standard they use. If you have self-made ZIM(s) or ZIM(s) downloaded from somewhere else, they most likely do not use the same naming standards and will not be processed by this script.
- If you have ZIM(s) from `download.kiwix.org`, but you have changed their file names, this script will treat them like the previous limitation explains.
- The new ZIM is downloaded before the old one is purged, so you need enough free space for both.
- This script does not attempt to update any `library.xml` that may or may not exist/be needed for your install/setup of Kiwix. If needed, you'll need to handle this part on your own.

## Requirements

This script does not need root, however it does need the same rights as your ZIM directory or it won't be able to download and/or purge ZIMs.

- Bash 4 or later.
- GNU coreutils: `numfmt`, `stat`, `du`, `sha256sum`, `timeout` (and GNU `date`).
- `flock` from util-linux.
- `wget` 1.x or GNU Wget2. Wget2 is supported: it follows metalinks by default, so the script passes `--no-metalink` to it for its metadata requests.
- `grep` with `-P` (PCRE) support.
- `git`, only if you use the self-update (`-U`).

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
    -S, --no-sha               Disables saving the zim checksum for future reference. Does not delete present checksums.
                               
Action Method Options:
    -w, --web                  Downloads zims over http(s).
    -t, --torrent              Downloads `.torrent` files. REQUIRES ADDITIONAL SOFTWARE TO EXECUTE DOWNLOAD.
    
    -f, --verify-library       Verifies that the entire library has the correct checksums as found online.
                               Expected behavior is to create sha256 files during a normal run so this option can be used at a later date without internet.
                               Disable this using -S

Web Download Options:
    -c, --calculate-checksum   Verifies that the downloaded files were not corrupted, but can take a while for large downloads.
    -p, --skip-purge           Skips purging any replaced ZIMs.
    -l <location>, --location  Country Code to prefer mirrors from
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
- **Interrupted downloads are resumed** on the next run instead of being deleted and started over.
- **GNU Wget2 support.**
- **One instance per ZIM directory**, enforced with `flock`.
- **`-S` works.** It used to be accepted but had no effect.
- **`download.log` and `kiwix-index`** always stay in the directory you run the script from.
- **ZIM listing.** Names with spaces and upper-case `.ZIM` extensions are handled, directories named `*.zim` are ignored, and a file whose name merely ends in a catalog name is no longer mistaken for that ZIM. Exported environment variables such as `SKIP_PURGE` no longer change the script's behaviour.
- **Startup checks** for all required tools.
- **The `kiwix-zim.sh` legacy name is dropped.** Running the script under that name no longer prints a deprecation warning or exits 2.
