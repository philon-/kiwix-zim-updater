#!/usr/bin/env bash

# Kiwix-Zim-Updater. A script to update your kiwix library
# Copyright (C) 2022      DocDrydenn
# Copyright (C) 2023-2026 jojo2357
# SPDX-License-Identifier: GPL-2.0-only

VER="3.5"

# This array will contain all of the local zims, with the file extension
LocalZIMArray=()
# This array will contain all of the local zims, without the file extension
LocalZIMNameArray=()
# This array will map the local zim to the index in the remote arrays that contains the same base file name
LocalZIMRemoteIndexArray=()
# What the download loop does with each local zim, one of the ACT_* values below
LocalActionArray=()
ACT_NONE=0            # nothing: up to date, outside the size limits, or not in the catalog
ACT_UPDATE=1          # download the catalog version; with -f, verify the current one and replace it when corrupt
ACT_VERIFY_CACHED=2   # -f: an outdated zim, verified against its cached .sha256
ACT_VERIFY_UNLISTED=3 # -f: a zim that is not in the catalog, verified against its cached .sha256
ACT_VERIFY_ONLINE=4   # -f: an outdated zim, verified against its own published .sha256

# This array stores the file names that kiwix has to offer, with .zim extensions
RemoteFiles=()
# Ditto, without the YYYY-MM (note a trailing _)
Basenames=()
# Contains the absolute path to this file, from /zims/
RemotePaths=()
# Contains the folder this file is in relative to /zims/
RemoteCategory=()
# Contains the catalog size of each remote file
FileSizes=()

# Set Script Strings
SCRIPT="$(readlink -f "$0")"
SCRIPTFILE="$(basename "$SCRIPT")"
SCRIPTPATH="$(dirname "$SCRIPT")"
ARGS=("$@")
BRANCH="main"
SELF_UPDATE=0 # -U: update this script from its git clone before running (off by default)
DEBUG=1 # This forces the script to default to "dry-run/simulation mode"
# Set when -d was given but the ZIM directory is not writable: the run falls back to dry-run and then exits 1
ForcedDryRun=0
MIN_SIZE=0
MAX_SIZE=0
MIN_FREE=1073741824 # --min-free: bytes to keep free in the ZIM directory after a download (1 GiB; 0 disables)
LIBRARY_XML="" # --library: kiwix library XML file to keep in sync with the ZIMs (for kiwix-serve --monitorLibrary)
LibraryFailed=0 # set when the library could not be rebuilt; the run then exits 1
CALCULATE_CHECKSUM=0
CHECKSUM_FILES=1
VERIFY_LIBRARY=0
CLEAN_PARTIALS=0 # --clean-partials: remove unfinished downloads (.part files) that can no longer be used
FORCE_FETCH_INDEX=0
DOWNLOAD_METHOD=1 # 1: web 2: torrent
SKIP_PURGE=0
COUNTRY_CODE="" # -l: preferred mirror country, empty for kiwix's default
POSITIONAL_ARGS=()
# Per-file download state, reset again for every ZIM in the download loop
DownloadFailed=0
IsMirror=0
DownloadURL=""
ExpectedSize=""
ExpectedHash=""
# Extra wget options for .meta4 requests and downloads. GNU Wget2 follows metalinks by default: it would hand us the
# ZIM itself instead of the metadata, and on a download it may follow the server's metalink headers instead of simply
# writing the -O file. wget 1.x rejects --no-metalink, so this is filled in by detect_wget_flavor.
WGET_META_OPTS=()
# Network limits for every request, so a stalled connection cannot hang an unattended run for hours (wget's defaults
# are 20 tries with a 15 minute read timeout). An interrupted download is simply resumed from its .part file next run.
WGET_NET_OPTS=(--connect-timeout=30 --read-timeout=300 --tries=3)
# sort of a default, will be overwritten when the library is parsed. Set here to what it probably will be
BaseURL="https://lb.download.kiwix.org/zim/"
CatalogURL="https://opds.library.kiwix.org/catalog/v2/entries?count=-1"
ZIMPath=""
# The log and the cached catalog live in the directory the script was started from. Resolve them once, so nothing
# that changes the working directory later can scatter them.
LOG_FILE="$PWD/download.log"
INDEX_FILE="$PWD/kiwix-index"

RED_REGULAR="\033[0;31m"
RED_BOLD="\033[1;31m"
YELLOW_REGULAR="\033[0;33m"
YELLOW_BOLD="\033[1;33m"
GREEN_REGULAR="\033[0;32m"
GREEN_BOLD="\033[1;32m"
BLUE_REGULAR="\033[0;34m"
BLUE_BOLD="\033[1;34m"
CLEAR="\033[0m"

MONTH_REGEX="\d{2}[a-z]?"
YEAR_REGEX="\d{4}"
END_ANCHOR_REGEX="\.zim"

COMPLETE_ENDING_REGEX="$YEAR_REGEX-$MONTH_REGEX$END_ANCHOR_REGEX"

# say <colour> <message> - Print the message in colour, and log it without the colour and the leading indent
say() {
  echo -e "$1$2${CLEAR}"
  echo "${2#"${2%%[! ]*}"}" >>"$LOG_FILE"
}

# This will ask the api what files it has to offer and store them in arrays
master_scrape() {
  unset RemoteFiles
  unset Basenames
  unset RemotePaths
  unset RemoteCategory

  indexIsValid=1

  if [[ ! -f "$INDEX_FILE" ]]; then
    indexIsValid=0
  else
    indexDate="$(head -1 "$INDEX_FILE")"
    # An index without links (left behind by older versions after a failed fetch) is never reused
    if [[ -z "${indexDate}" ]] || [[ "$(date -u -d "$indexDate" +%s)" -lt "$(date -u -d "1 day ago" +%s)" ]] || ! grep -qi '<link rel' "$INDEX_FILE"; then
      indexIsValid=0
    fi
  fi

  if [[ FORCE_FETCH_INDEX -eq 1 ]] || [[ $indexIsValid -eq 0 ]]; then
    # Fetch the catalog, then cache its timestamp (first line) and all of its links in the index file.
    # The index is only replaced once the fetch succeeded and parsed, so a failure never caches an empty index.
    local rawCatalog fetchStatus catalogDate indexTmp
    rawCatalog="$(wget "${WGET_NET_OPTS[@]}" --show-progress -q -O - "$CatalogURL")"
    fetchStatus=$?
    if [[ $fetchStatus -ne 0 ]]; then
      say "${RED_REGULAR}" "    ✗ Could not fetch the online catalog (wget exit $fetchStatus). Exiting..."
      exit 1
    fi
    catalogDate="$(echo "$rawCatalog" | grep -ioP "(?<=<updated>)\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?=Z</updated>)" | head -1)"
    RawLibrary="$(echo "$rawCatalog" | grep -i 'application/x-zim' | grep -ioP "^\s+\K.*$")"
    unset rawCatalog
    if [[ -z "$catalogDate" ]]; then
      say "${RED_REGULAR}" "    ✗ The online catalog has no <updated> date. Exiting..."
      exit 1
    fi
    if [[ -z "$RawLibrary" ]]; then
      echo -e "${RED_REGULAR}  ✗ No ZIM URLs found. Exiting...${CLEAR}"
      echo "✗ No ZIM URLs found in the online catalog. Exiting..." >> "$LOG_FILE"
      exit 1
    fi
    indexTmp="$INDEX_FILE.tmp.$$"
    if ! { printf '%s\n%s\n' "$catalogDate" "$RawLibrary" > "$indexTmp" && mv -f "$indexTmp" "$INDEX_FILE"; }; then
      rm -f "$indexTmp"
      echo -e "${YELLOW_REGULAR}    Could not cache the online catalog in $INDEX_FILE, continuing without it${CLEAR}"
      echo "Could not cache the online catalog in $INDEX_FILE" >> "$LOG_FILE"
    fi
  else
    RawLibrary=$(grep -i '<link rel' < "$INDEX_FILE")
  fi

  REMOTE_FILE_REGEX="[^/]/\K[\w:\/\-.]+"
  BASE_REGEX="[^/]/\K[\w:\/\-.]+(?=$COMPLETE_ENDING_REGEX)"
  REMOTE_PATH_REGEX="^[\w:\/\-.]+"
  REMOTE_CATEGORY_REGEX="^[^/]+"

  ValidLibrary="$RawLibrary"
  # ensure that every line matches every regex
  ValidLibrary="$(echo "$ValidLibrary" | grep -iP '(?<=length=")\d+(?=")')"
  ValidLibrary="$(echo "$ValidLibrary" | grep -iP "(?<=href=\")[\w:\/\-.]+(?=\.meta4\")")"
  # we have to add extra here so that we dont have to change the regexes
  ValidLibrary="$(echo "$ValidLibrary" | grep -iP "href=\"https?://[^/]+$REMOTE_FILE_REGEX")"
  ValidLibrary="$(echo "$ValidLibrary" | grep -iP "href=\"https?://[^/]+$BASE_REGEX")"

  IFS=$'\n' read -r -d '' -a FileSizes < <(echo "$ValidLibrary" | grep -ioP '(?<=length=")\d+(?=")')
  unset IFS

  RawLinks=$(echo "$ValidLibrary" | grep -ioP "(?<=href=\")[\w:\/\-.]+(?=\.meta4\")")

  BaseURL=$(echo "$RawLinks" | grep -ioP 'https?://[^/]+' | uniq)

  FoundURLs=$(echo "$BaseURL" | wc -l)

  if [[ -z "$BaseURL" ]]; then
    echo -e "${RED_REGULAR}  ✗ No ZIM URLs found. Exiting...${CLEAR}"
    exit 1
  elif [[ $FoundURLs -ne 1 ]]; then
    echo -e "${RED_REGULAR}  ✗ Too many zim base urls found. Please open an issue on github. Exiting...${CLEAR}"
    exit 1
  else
    BaseURL="$BaseURL/zim/"
    echo -e "${GREEN_REGULAR}    ✓ Using $BaseURL as base download directory for metadata"
  fi

  hrefs=$(echo "$ValidLibrary" | grep -ioP "(?<=href=\")[\w:\/\-.]+(?=\.meta4\")" | grep -ioP "$BaseURL\K.*")

  IFS=$'\n' read -r -d '' -a RemoteFiles < <(echo "$hrefs" | grep -ioP "$REMOTE_FILE_REGEX")
  unset IFS
  IFS=$'\n' read -r -d '' -a Basenames < <(echo "$hrefs" | grep -ioP "$BASE_REGEX")
  unset IFS
  IFS=$'\n' read -r -d '' -a RemotePaths < <(echo "$hrefs" | grep -ioP "$REMOTE_PATH_REGEX")
  unset IFS # distinct from above for processing speed reasons
  IFS=$'\n' read -r -d '' -a RemoteCategory < <(echo "$hrefs" | grep -ioP "$REMOTE_CATEGORY_REGEX")
  unset IFS

  if [[ ${#RemoteFiles[@]} -eq 0 ]]; then
    say "${RED_REGULAR}" "    ✗  Could not find any remote files, exiting"
    exit 1
  else
    say "${GREEN_BOLD}" "    ✓ Found ${#RemoteFiles[@]} files online"
  fi

  if [[ ${#RemoteFiles[@]} -ne ${#Basenames[@]} ]] || \
    [[ ${#RemoteFiles[@]} -ne ${#RemotePaths[@]} ]] || \
    [[ ${#RemoteFiles[@]} -ne ${#RemoteCategory[@]} ]] || \
    [[ ${#RemoteFiles[@]} -ne ${#FileSizes[@]} ]] ; then
    echo -e "${RED_BOLD}CRITICAL ERROR!${CLEAR}"
    echo -e "${RED_REGULAR}Parsed array lengths did not match. Aborting to prevent data loss${CLEAR}"
    exit 1
  fi

  # Housekeeping...
  unset ValidLibrary
  unset RawLibrary
  unset hrefs
}

# self_update - Script Self-Update Function. Only with -U, only on a clean clone on $BRANCH, and only by fast-forward.
# Any failure is reported and the run continues with the current version. After an update the new version is run with
# the same arguments; KIWIX_ZIM_UPDATER_UPDATED (deliberately read from the environment) stops it from updating again.
self_update() {
  local fetchStatus diffStatus oldHead newHead
  say "${YELLOW_BOLD}" "1. Checking for Script Updates..."
  echo
  if [[ $SELF_UPDATE -ne 1 ]]; then
    say "${YELLOW_REGULAR}" "   Check Skipped (use -U to enable)"
    echo
    return
  fi
  if [[ -n "${KIWIX_ZIM_UPDATER_UPDATED:-}" ]]; then
    unset KIWIX_ZIM_UPDATER_UPDATED
    say "${GREEN_BOLD}" "   ✓ Running the updated version"
    echo
    return
  fi
  if [[ ! -e "$SCRIPTPATH/.git" ]]; then
    say "${RED_REGULAR}" "   ✗ Git Clone Not Detected: Skipping Update Check"
    echo
    return
  fi
  say "${GREEN_BOLD}" "   ✓ Git Clone Detected: Checking Script Version..."
  if [[ $(timeout 10s git -C "$SCRIPTPATH" rev-parse --abbrev-ref HEAD) != "$BRANCH" ]]; then
    echo -e "${YELLOW_BOLD}     You appear to be on a different branch so I will assume you are developing and do not want an update${CLEAR}"
    echo "Not on branch $BRANCH: Skipping Update" >> "$LOG_FILE"
    echo
    return
  fi
  # Never prompt for credentials (nobody answers under cron) and never hang for long on the network
  GIT_TERMINAL_PROMPT=0 timeout 30s git -C "$SCRIPTPATH" fetch --quiet origin
  fetchStatus=$?
  if [[ $fetchStatus -ne 0 ]]; then
    say "${RED_REGULAR}" "   ✗ Could not fetch updates (git exit $fetchStatus): Continuing with the current version"
    echo
    return
  fi
  timeout 10s git -C "$SCRIPTPATH" diff --quiet --exit-code "origin/$BRANCH" -- "$SCRIPTFILE"
  diffStatus=$?
  if [[ $diffStatus -eq 0 ]]; then
    say "${GREEN_BOLD}" "   ✓ Version: Current"
    echo
    return
  elif [[ $diffStatus -ne 1 ]]; then
    say "${RED_REGULAR}" "   ✗ Could not compare with origin/$BRANCH (git exit $diffStatus): Continuing with the current version"
    echo
    return
  fi
  say "${RED_REGULAR}" "   ✗ Version: Mismatched"
  echo
  say "${YELLOW_BOLD}" "1a. Fetching Update..."
  echo
  # Local work is never stashed, reset or overwritten: a modified clone is left alone
  if [[ -n "$(git -C "$SCRIPTPATH" status --porcelain)" ]]; then
    say "${RED_REGULAR}" "   ✗ $SCRIPTPATH has local changes: Not updating, continuing with the current version"
    echo
    return
  fi
  oldHead="$(git -C "$SCRIPTPATH" rev-parse HEAD)"
  if ! GIT_TERMINAL_PROMPT=0 timeout 30s git -C "$SCRIPTPATH" pull --ff-only --no-rebase --quiet origin "$BRANCH"; then
    say "${RED_REGULAR}" "   ✗ Update failed (no fast-forward possible?): Continuing with the current version"
    echo
    return
  fi
  newHead="$(git -C "$SCRIPTPATH" rev-parse HEAD)"
  if [[ "$newHead" == "$oldHead" ]]; then
    echo -e "${YELLOW_REGULAR}   Nothing to fast-forward (local commits ahead of origin/$BRANCH?): Continuing with the current version${CLEAR}"
    echo "Nothing to fast-forward: Continuing with the current version" >> "$LOG_FILE"
    echo
    return
  fi
  say "${GREEN_BOLD}" "   ✓ Update Complete. Running New Version. Standby..."
  sleep 3

  export KIWIX_ZIM_UPDATER_UPDATED=1
  # Run the updated file through bash by its absolute path: $0 may be a bare name (bash kiwix-zim-updater.sh) or a
  # file without the executable bit, either of which would make a plain exec fail.
  exec bash "$SCRIPT" "${ARGS[@]}"

  # Exit this old instance of the script
  exit 1
}

# usage_example [<exit code>] - Show Usage and Exit (default 0). On a usage error the text goes to stderr.
# shellcheck disable=SC2016 # the backticks in the help text are meant literally, nothing should expand
usage_example() {
  local status="${1:-0}"
  [[ "$status" -ne 0 ]] && exec 1>&2 # we exit below, so redirecting the rest of the script is harmless
  echo 'Usage: ./kiwix-zim-updater.sh <options> /full/path/'
  echo ''
  echo '    /full/path/                Full path to ZIM directory'
  echo ''
  echo 'Universal Options:'
  echo '    -h, --help                 Show this usage and exit.'
  echo '    -U, --self-update          Updates this script from its git clone before running (off by default).'
  echo '    -u, --skip-update          Accepted for compatibility; self-update is now off unless -U is given.'
  echo '    -g, --get-index            Forces using remote index rather than cached index. Cache auto clears after one day'
  echo '    -n <size>, --min-size      Minimum ZIM Size to be downloaded.'
  echo '                               Specify units include M Mi G Gi, etc. See `man numfmt`'
  echo '    -x <size>, --max-size      Maximum ZIM Size to be downloaded.'
  echo '                               Specify units include M Mi G Gi, etc. See `man numfmt`'
  echo '    --min-free <size>          Free space to keep in the ZIM directory after a download (default 1Gi, 0 disables).'
  echo '                               A download that would leave less is skipped and the old ZIM kept.'
  echo '    --library <file>           Keeps a kiwix library XML file listing the finished ZIMs up to date, for'
  echo '                               kiwix-serve --library --monitorLibrary. Best placed in the ZIM directory.'
  echo '    -S, --no-sha               Disables saving the zim checksum for future reference. Does not delete present checksums.'
  echo '                               '
  echo 'Action Method Options:'
  echo '    -w, --web                  Downloads zims over http(s).'
  echo '    -t, --torrent              Downloads `.torrent` files. REQUIRES ADDITIONAL SOFTWARE TO EXECUTE DOWNLOAD.'
  echo '    '
  echo '    -f, --verify-library       Verifies that the entire library has the correct checksums as found online.'
  echo '                               Expected behavior is to create sha256 files during a normal run so this option can be used at a later date without internet.'
  echo '                               Use -S to stop new .sha256 files from being written.'
  echo ''
  echo 'Web Download Options:'
  echo '    -c, --calculate-checksum   Verifies that the downloaded files were not corrupted, but can take a while for large downloads.'
  echo '    -p, --skip-purge           Skips purging any replaced ZIMs.'
  echo '    -l <location>, --location  Country Code to prefer mirrors from'
  echo '    --clean-partials           Deletes unfinished downloads (.part files) whose release left the catalog, or'
  echo '                               whose finished ZIM -f has just verified as good.'
  echo '    -d, --disable-dry-run      Dry-Run Override.'
  echo '                               *** Caution ***'

  echo
  exit "$status"
}

# usage_error <message> - Report a bad command line on stderr, show the usage and exit 2
usage_error() {
  echo -e "${RED_REGULAR}  ✗ $1${CLEAR}" >&2
  echo >&2
  usage_example 2
}

# flags - Flag and ZIM Processing Functions
flags() {
  say "${YELLOW_BOLD}" "2. Preprocessing..."
  echo
  echo -e "${BLUE_BOLD}  -Validating ZIM directory...${CLEAR}"
  echo "Validating ZIM directory..." >> "$LOG_FILE"

  # Let's identify which argument is the ZIM directory path and if it's an actual directory.
  if [[ -d ${1} ]]; then
    if [[ -w ${1} ]]; then
      ZIMPath=$1
    else
      ZIMPath=$1
      say "${RED_REGULAR}" "  ✗ Cannot write to '${1}', continuing in dry-run"
      echo
      # -d was asked for but cannot be honoured: finish the run as a simulation, then report it as a failure
      [[ $DEBUG -eq 0 ]] && ForcedDryRun=1
      DEBUG=1
    fi
  else # Um... no ZIM directory path provided? Okay, let's show the usage and exit.
    if [[ -z ${1} ]]; then
      say "${RED_REGULAR}" "  ✗ Kiwix ZIM Directory not provided"
    else
      say "${RED_REGULAR}" "  ✗ '$1' is not a directory"
    fi
    echo
    usage_example 2
  fi

  # Check for and add if missing, trailing slash.
  [[ "${ZIMPath}" != */ ]] && ZIMPath="${ZIMPath}/"

  # Now we need to check for ZIM files.
  shopt -s nullglob # This is in case there are no matching files

  # Load all found ZIM(s) into LocalZIMArray: names without the path, regular files only, hidden files skipped like
  # `ls -1` does. The glob sorts like `ls -1` (by LC_COLLATE), so the shadowing check below sees the same order.
  LocalZIMArray=()
  for zimFile in "$ZIMPath"*.[zZ][iI][mM]; do
    zimFile="${zimFile##*/}"
    [[ "$zimFile" == .* ]] && continue
    # The line-based parsing below would split a name with a newline and mistake it for another ZIM: leave it alone
    [[ "$zimFile" == *$'\n'* ]] && continue
    [[ -f "$ZIMPath$zimFile" ]] && LocalZIMArray+=("$zimFile")
  done

  for index in "${!LocalZIMArray[@]}" ; do
    duplicated=0
    myBasename=$(echo "${LocalZIMArray[$index]}" | grep -ioP "^.*(?=_$COMPLETE_ENDING_REGEX$)")

    # Sorting cannot reliably sort the month string so we need to check it to be sure
    MyDate="$(zim_date "${LocalZIMArray[$index]}")"

    for scanIndex in "${!LocalZIMArray[@]}"; do
      if [[ -f "${ZIMPath}.~lock.${LocalZIMArray[$index]}" ]]; then
        if [[ $index -le $scanIndex ]] || [[ -f "${ZIMPath}.~lock.${LocalZIMArray[$scanIndex]}" ]]; then continue; fi
      else
        if [[ $index -ge $scanIndex ]] || [[ -f "${ZIMPath}.~lock.${LocalZIMArray[$scanIndex]}" ]]; then continue; fi
      fi
      scanBasename=$(echo "${LocalZIMArray[$scanIndex]}" | grep -ioP "^.*(?=_$COMPLETE_ENDING_REGEX$)")

      if [[ "$myBasename" == "$scanBasename" ]]; then
        if [[ -f "${ZIMPath}.~lock.${LocalZIMArray[$index]}" ]]; then
          echo "Disregarding ${LocalZIMArray[$index]} because it was interrupted by ${LocalZIMArray[$scanIndex]}" >> "$LOG_FILE"
        elif [[ -f "${ZIMPath}${LocalZIMArray[$index]}.torrent" ]]; then
          echo "Disregarding ${LocalZIMArray[$index]} because new torrent exists ${LocalZIMArray[$scanIndex]}" >> "$LOG_FILE"
        else
          ScanDate="$(zim_date "${LocalZIMArray[$scanIndex]}")"

          # this file is not shadowed if it is newer.
          # this is caused by `ls -1` and `sort` having weird lexicons that make the prefix sort unreliable that 02a can sort between 01 and 02 instead of after 02
          if zim_is_newer "$MyDate" "$ScanDate"; then
            echo "Disregarding ${LocalZIMArray[$scanIndex]} because it is shadowed by ${LocalZIMArray[$index]}" >> "$LOG_FILE"
            duplicated=2
            break
          fi

          echo "Disregarding ${LocalZIMArray[$index]} because it is shadowed by ${LocalZIMArray[$scanIndex]}" >> "$LOG_FILE"
        fi
        duplicated=1
        break
      fi
    done
    [[ $duplicated -eq 1 ]] && unset -v 'LocalZIMArray[$index]'
    [[ $duplicated -eq 2 ]] && unset -v 'LocalZIMArray[$scanIndex]'
  done
  LocalZIMArray=("${LocalZIMArray[@]}")

  # Check that ZIM(s) were actually found/loaded.
  if [ ${#LocalZIMArray[@]} -eq 0 ]; then # No ZIM(s) were found in the directory... I guess there's nothing else for us to do, so we'll Exit.
    echo -e "${RED_REGULAR}  ✗ No ZIMs found. Exiting...${CLEAR}"
    exit 1
  else
    echo -e "${GREEN_BOLD}  ✓ Valid ZIM Directory ${CLEAR}"
  fi
  echo

  acquire_zim_dir_lock
  echo -e "${BLUE_BOLD}  -Building online ZIM list...${CLEAR}"

  # Build online ZIM list.
  master_scrape

  echo

  # Populate ZIM arrays from found ZIM(s)
  echo -e "${BLUE_BOLD}  -Parsing ZIM(s)...${CLEAR}"

  for ((i = 0; i < ${#LocalZIMArray[@]}; i++)); do                                             # Loop through local ZIM(s).
    LocalZIMNameArray[i]=$(basename "${LocalZIMArray[$i]}")                                   # Extract file name.
    filename=$(basename "${LocalZIMArray[$i]}" | grep -ioP "^[\w:\/\-.]+(?=$COMPLETE_ENDING_REGEX$)") # Extract file name.

    # Search MasterZIMArray for the current local ZIM to discover the online Root (directory) for the URL
    for ((z = 0; z < ${#Basenames[@]}; z++)); do
      if [[ ${Basenames[$z]} == "$filename" ]]; then # Match Found (ignore the filename datepart).
        LocalZIMRemoteIndexArray[i]="$z"
        break
      else # No Match Found.
        LocalZIMRemoteIndexArray[i]="-1"
      fi
    done

    if [[ ${LocalZIMRemoteIndexArray[i]} -eq -1 ]]; then
      echo -e "${RED_REGULAR}    ✗ ${LocalZIMNameArray[$i]}  No online match found.${CLEAR}"
    else
      echo -e "${GREEN_BOLD}    ✓ ${LocalZIMNameArray[$i]}  [${RemoteCategory[${LocalZIMRemoteIndexArray[$i]}]}]${CLEAR}"
    fi
  done

  echo
  echo -e "${GREEN_REGULAR}    ${#LocalZIMNameArray[*]} ZIM(s) found.${CLEAR}"
}

# detect_wget_flavor - GNU Wget2 follows metalinks unless told not to; wget 1.x does not know the option
detect_wget_flavor() {
  WGET_META_OPTS=()
  if wget --version 2>/dev/null | head -n 1 | grep -qi 'wget2'; then
    WGET_META_OPTS=(--no-metalink)
  fi
}

# check_dependencies - Make sure every external tool the run needs is present before doing any work
check_dependencies() {
  local missing=() tool
  for tool in wget numfmt sha256sum flock stat du df timeout; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  # The parsing relies on Perl-compatible regular expressions, which not every grep has
  echo x | grep -qP 'x' 2>/dev/null || missing+=("grep -P")
  # kiwix-manage (kiwix-tools) is only needed to maintain a library file
  if [[ -n "$LIBRARY_XML" ]]; then
    command -v kiwix-manage >/dev/null 2>&1 || missing+=("kiwix-manage")
    command -v cmp >/dev/null 2>&1 || missing+=("cmp")
  fi
  # git is only needed when the self-update would actually run
  if [[ $SELF_UPDATE -eq 1 ]] && [[ -e "$SCRIPTPATH/.git" ]]; then
    command -v git >/dev/null 2>&1 || missing+=("git")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED_BOLD}✗ Missing required tool(s): ${missing[*]}. Please install them and try again. Exiting...${CLEAR}" >&2
    echo "✗ Missing required tool(s): ${missing[*]}. Exiting..." >> "$LOG_FILE"
    exit 1
  fi
}

# acquire_zim_dir_lock - Refuse to run while another instance works on the same ZIM directory. The lock is taken on
# the directory itself (opened read-only on fd 9), so no lock file is created and read-only directories work too.
# It is held until the script exits.
acquire_zim_dir_lock() {
  if ! exec 9<"$ZIMPath"; then
    say "${RED_BOLD}" "  ✗ Cannot open '$ZIMPath' to lock it. Exiting..." >&2
    exit 1
  fi
  if ! flock -n 9; then
    say "${RED_BOLD}" "  ✗ Another instance is already running on '$ZIMPath'. Exiting..." >&2
    exit 75
  fi
}

# zim_date <file name> - Print the YYYY-MM[a-z] release date at the end of a ZIM file name, nothing if it has none.
# The extension is matched case-insensitively like the ZIM listing (foo_2026-01.ZIM), and the date is printed in
# lower case so it compares like the catalog's dates.
zim_date() {
  echo "$1" | grep -ioP "$YEAR_REGEX-$MONTH_REGEX(?=$END_ANCHOR_REGEX$)" | tr '[:upper:]' '[:lower:]'
}

# zim_is_newer <date> <other date> - True if the first YYYY-MM[a-z] date (as printed by zim_date) is newer than the
# second. The year is compared first, then the month as a string, so 2026-02a is newer than 2026-02, which is newer
# than 2026-01b. Equal dates are not newer, and an empty date is older than any other.
zim_is_newer() {
  local year month otherYear otherMonth
  year="$(echo "$1" | grep -oP "$YEAR_REGEX(?=-$MONTH_REGEX)")"
  month="$(echo "$1" | grep -oP "(?<=$YEAR_REGEX-)$MONTH_REGEX")"
  otherYear="$(echo "$2" | grep -oP "$YEAR_REGEX(?=-$MONTH_REGEX)")"
  otherMonth="$(echo "$2" | grep -oP "(?<=$YEAR_REGEX-)$MONTH_REGEX")"
  [[ "$year" > "$otherYear" ]] || { [[ "$year" == "$otherYear" ]] && [[ "$month" > "$otherMonth" ]]; }
}

# cleanup_partials - Report (and with --clean-partials remove) unfinished downloads in the ZIM directory.
# Nothing that could still be useful is deleted: a .part file is removed only with --clean-partials, and only when its
# release is no longer in the catalog, or when -f verified its finished ZIM as good in this run (a .part next to an
# existing ZIM is otherwise the replacement for a corrupt one, which the next -f run resumes). Files behind a `.~lock.` marker (left by older
# versions of this script, which downloaded straight into the ZIM's name) are never deleted; only a marker whose file
# is gone is removed. In dry-run nothing is changed, the would-be actions are listed.
cleanup_partials() {
  local partFiles lockFiles part partName lock lockName header=0 simulated=""
  [[ $DEBUG -eq 1 ]] && simulated="*** Simulated *** "
  partFiles=("$ZIMPath"*.zim.part)
  lockFiles=("$ZIMPath".~lock.*.zim)
  [[ ${#partFiles[@]} -eq 0 ]] && [[ ${#lockFiles[@]} -eq 0 ]] && return 0

  say "${YELLOW_BOLD}" "5. Cleaning up..."
  echo

  for part in "${partFiles[@]}"; do
    [[ -f "$part" ]] || continue
    partName="${part##*/}"
    partName="${partName%.part}"
    if [[ " ${ResumableParts[*]} " == *" $part "* ]]; then
      say "${YELLOW_BOLD}" "  Keeping interrupted download for the next run to resume: $part"
    elif [[ " ${RemoteFiles[*]} " != *" $partName "* ]] || [[ " ${VerifiedZIMs[*]} " == *" $partName "* ]]; then
      # Useless: the release left the catalog so it can never be resumed, or its finished ZIM was just verified good
      if [[ $CLEAN_PARTIALS -eq 1 ]]; then
        say "${BLUE_BOLD}" "  ${simulated}Removing unfinished download that can no longer be used: $part"
        [[ $DEBUG -eq 0 ]] && rm -f "$part"
      else
        echo -e "  ${YELLOW_BOLD}Unfinished download that can no longer be used: $part (--clean-partials removes it)${CLEAR}"
        echo "Unfinished download that can no longer be used: $part" >> "$LOG_FILE"
      fi
    else
      say "${YELLOW_BOLD}" "  Keeping unfinished download for a later run to resume: $part"
    fi
    header=1
  done

  for lock in "${lockFiles[@]}"; do
    [[ -f "$lock" ]] || continue
    lockName="${lock##*/}"
    lockName="${lockName#.~lock.}"
    if [[ ! -f "$ZIMPath$lockName" ]]; then
      say "${BLUE_BOLD}" "  ${simulated}Removing stale lock without a download: $lock"
      if [[ -f "$ZIMPath$lockName.sha256" ]]; then
        say "${BLUE_BOLD}" "  ${simulated}Removing its abandoned checksum: $ZIMPath$lockName.sha256"
        [[ $DEBUG -eq 0 ]] && rm -f "$ZIMPath$lockName.sha256"
      fi
      [[ $DEBUG -eq 0 ]] && rm -f "$lock"
    else
      echo -e "  ${YELLOW_BOLD}Keeping an interrupted download left by an older version of this script: $ZIMPath$lockName${CLEAR}"
      echo -e "  ${YELLOW_BOLD}  It is resumed when that ZIM is updated again; delete it and $lock if you no longer need it.${CLEAR}"
      echo "Keeping an interrupted download left by an older version of this script: $ZIMPath$lockName (lock $lock)" >> "$LOG_FILE"
    fi
    header=1
  done
  [[ $header -eq 1 ]] && echo
  return 0
}

# other_local_version_exists <title> <name> - True if the ZIM directory holds a .zim of the same title (<title> is the
# catalog base name including its trailing "_", e.g. wikipedia_en_all_maxi_) other than <name>
other_local_version_exists() {
  local f rest
  for f in "$ZIMPath$1"*.[zZ][iI][mM]; do
    [[ -f "$f" ]] || continue
    f="${f##*/}"
    [[ "$f" == "$2" ]] && continue
    rest="${f#"$1"}"
    [[ "$rest" =~ ^[0-9]{4}-[0-9]{2}[a-zA-Z]?\.[zZ][iI][mM]$ ]] && return 0
  done
  return 1
}

# rebuild_library - Bring the --library file in line with the finished ZIMs in the ZIM directory. It lists what is there:
# a download only becomes a .zim (and so a candidate) once verified, .part files never match, and a .zim behind an
# old-style `.~lock.` marker is an unfinished download. Existing ZIMs are not verified here; that is what -f is for.
# Nothing happens in dry-run or without --library. kiwix-serve --monitorLibrary picks up the change by itself.
# - The new library is built in a temporary file, one ZIM at a time (kiwix-manage gives up on all of them when one
#   cannot be read); unreadable ZIMs are reported and left out.
# - It is written into the existing file in place, and only when it changed: kiwix-serve 3.8 stops noticing changes
#   once the file is replaced by a rename. A half-written file is harmless (kiwix-serve keeps the books it has when a
#   reload fails), and a touch two seconds later makes it reload the finished file in any case.
# - If no ZIM could be added although there are some, the existing library is left alone.
rebuild_library() {
  [[ -n "$LIBRARY_XML" ]] || return 0
  [[ $DEBUG -eq 0 ]] || return 0
  local tmp="$LIBRARY_XML.tmp.$$" zim name added=0 failed=0
  rm -f "$tmp"
  for zim in "$ZIMPath"*.[zZ][iI][mM]; do
    [[ -f "$zim" ]] || continue
    name="${zim##*/}"
    [[ "$name" == .* ]] && continue
    [[ -f "$ZIMPath.~lock.$name" ]] && continue
    if kiwix-manage "$tmp" add "$zim" >/dev/null 2>&1; then
      added=$((added + 1))
    else
      failed=$((failed + 1))
      say "${YELLOW_BOLD}" "    Library: $name could not be read by kiwix-manage and is left out of $LIBRARY_XML"
    fi
  done
  if [[ $added -eq 0 ]]; then
    if [[ $failed -gt 0 ]]; then
      say "${RED_BOLD}" "    ✗ Library: no ZIM could be added, $LIBRARY_XML is left as it is"
      rm -f "$tmp"
      LibraryFailed=1
      return 1
    fi
    printf '<library version="20110515">\n</library>\n' >"$tmp" 2>/dev/null
  fi
  if [[ ! -f "$tmp" ]]; then
    say "${RED_BOLD}" "    ✗ Library: could not write $tmp"
    LibraryFailed=1
    return 1
  fi
  if [[ -f "$LIBRARY_XML" ]] && cmp -s "$tmp" "$LIBRARY_XML"; then
    rm -f "$tmp"
    return 0
  fi
  if cat "$tmp" >"$LIBRARY_XML"; then
    rm -f "$tmp"
    say "${GREEN_REGULAR}" "    ✓ Library: $LIBRARY_XML now lists $added ZIM(s)"
    # The second change event, in its own process; it must not hold the ZIM directory lock (fd 9) after the run
    (exec 9<&-; sleep 2; touch "$LIBRARY_XML" 2>/dev/null) >/dev/null 2>&1 &
    return 0
  fi
  rm -f "$tmp"
  say "${RED_BOLD}" "    ✗ Library: could not write $LIBRARY_XML"
  LibraryFailed=1
  return 1
}

# free_bytes <dir> - Print the bytes available to this user in the file system holding <dir> (empty if unknown)
free_bytes() {
  df -B1 --output=avail -- "$1" 2>/dev/null | tail -n 1 | tr -d ' '
}

# hash_matches <name> <hash> - True if $ZIMPath<name> has the given sha256. Needs no .sha256 file on disk.
hash_matches() {
  (cd "$ZIMPath" && printf '%s  %s\n' "$2" "$1" | sha256sum --status -c - 2>/dev/null)
}

# write_checksum_file <name> <hash> - Store the checksum next to the ZIM for later offline verification (-f).
# Never in dry-run, never with -S, and never with a hash that does not look like a sha256 (e.g. when the meta4 fetch
# failed).
write_checksum_file() {
  [[ $DEBUG -eq 0 ]] || return 0
  [[ $CHECKSUM_FILES -eq 1 ]] || return 0
  [[ "$2" =~ ^[0-9a-f]{64}$ ]] || return 0
  # Leave an existing checksum file alone when it already holds this hash
  [[ -f "$ZIMPath$1.sha256" ]] && [[ "$(grep -ioP "^[0-9a-f]{64}" <"$ZIMPath$1.sha256")" == "$2" ]] && return 0
  echo "$2 $1" >"$ZIMPath$1.sha256.tmp" && mv -f "$ZIMPath$1.sha256.tmp" "$ZIMPath$1.sha256"
}

# download_file - Download (or resume) $2 into $1, showing progress and logging it. Returns wget's own exit status,
# not tee's.
download_file() {
  wget "${WGET_NET_OPTS[@]}" "${WGET_META_OPTS[@]}" -q --show-progress --progress=bar:force -c -O "$1" "$2" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

# mirror_search - Find ZIM URL Priority #1 mirror from meta4 Function
mirror_search() {
  IsMirror=0
  DownloadURL=""
  RemotePath="${RemotePaths[${LocalZIMRemoteIndexArray[$z]}]}"
  ExpectedSize="${FileSizes[${LocalZIMRemoteIndexArray[$z]}]}"

  # If we need the checksum, we need a link  and the hash, which we can get both by using .meta4, otherwise we only need
  # Silently fetch (via wget) the associated meta4 xml and extract the mirror URL marked priority="1"
  MetaInfo=$(wget "${WGET_NET_OPTS[@]}" "${WGET_META_OPTS[@]}" -q -O - "$BaseURL$RemotePath.meta4?country=$COUNTRY_CODE")
  ExpectedSize=$(echo "$MetaInfo" | grep '<size>' | grep -Po '\d+')
  ExpectedHash=$(echo "$MetaInfo" | grep '<hash type="sha-256">' | grep -Poi '(?<="sha-256">)[a-f\d]{64}(?=<)')

  # still run the last wget so that the logic is simple for verification.
  if [[ $DOWNLOAD_METHOD -eq 2 ]]; then
    DownloadURL="$BaseURL$RemotePath.torrent" # Set the direct download URL as our download URL
    return
  fi

  RawMirror=$(echo "$MetaInfo" | grep 'priority="1"' | grep -Po 'https?://[^ ")]+(?=</url>)')

  # Check that we actually got a URL (this could probably be done better). If no mirror URL, default back to direct URL.
  if [[ $RawMirror == *"http"* ]]; then # Mirror URL found
    DownloadURL="$RawMirror"            # Set the mirror URL as our download URL
    IsMirror=1
  else                                # Mirror URL not found
    DownloadURL="$BaseURL$RemotePath" # Set the direct download URL as our download URL
  fi
}

#########################
# Begin Script Execute
#########################

main() {
  CountryCodeWarning="" # shown after the screen is cleared
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help)
        usage_example 0
        ;;
      -d | --disable-dry-run)
        DEBUG=0
        shift # discard argument
        ;;
      -v | --version)
        echo "$VER"
        exit 0
        ;;
      -p | --skip-purge)
        SKIP_PURGE=1
        shift # discard argument
        ;;
      -n | --min-size)
        [[ $# -lt 2 ]] && usage_error "$1 requires a size"
        shift                               # discard -n argument
        MIN_SIZE=$(numfmt --from=auto "$1" 2>/dev/null) # convert passed arg to bytes
        [[ "$MIN_SIZE" =~ ^[0-9]+$ ]] || usage_error "Invalid minimum size: '$1'"
        shift                               # discard value
        ;;
      --library)
        { [[ $# -lt 2 ]] || [[ -z "$2" ]] || [[ "$2" == -* ]]; } && usage_error "$1 requires a file name"
        shift
        LIBRARY_XML="$1"
        [[ "$LIBRARY_XML" == /* ]] || LIBRARY_XML="$PWD/$LIBRARY_XML"
        shift
        ;;
      --min-free)
        [[ $# -lt 2 ]] && usage_error "$1 requires a size"
        shift
        MIN_FREE=$(numfmt --from=auto "$1" 2>/dev/null)
        [[ "$MIN_FREE" =~ ^[0-9]+$ ]] || usage_error "Invalid free space reserve: '$1'"
        shift
        ;;
      -x | --max-size)
        [[ $# -lt 2 ]] && usage_error "$1 requires a size"
        shift                               # discard -x argument
        MAX_SIZE=$(numfmt --from=auto "$1" 2>/dev/null) # convert passed arg to bytes
        [[ "$MAX_SIZE" =~ ^[0-9]+$ ]] || usage_error "Invalid maximum size: '$1'"
        shift                               # discard value
        ;;
      -l | --location)
        { [[ $# -lt 2 ]] || [[ "$2" == -* ]]; } && usage_error "$1 requires a country code"
        shift # discard -l argument
        if [[ "$1" =~ ^[A-Z]{2}$ ]]; then
          COUNTRY_CODE=$1
        else
          COUNTRY_CODE=""
          CountryCodeWarning="Invalid country code '$1', falling back to default kiwix behavior"
          echo "Invalid country code, falling back to default kiwix behavior" >> "$LOG_FILE"
        fi
        shift # discard value
        ;;
      -c | --calculate-checksum)
        CALCULATE_CHECKSUM=1
        shift
        ;;
      -f | --verfiy-library | --verify-library)
        VERIFY_LIBRARY=1
        CALCULATE_CHECKSUM=1
        shift
        ;;
      -U | --self-update)
        SELF_UPDATE=1
        shift
        ;;
      -u | --skip-update)
        shift # no-op since self-update became opt-in (-U); still accepted so existing cron lines keep working
        ;;
      -g | --get-index)
        FORCE_FETCH_INDEX=1
        shift
        ;;
      -w | --web)
        DOWNLOAD_METHOD=1
        shift
        ;;
      -t | --torrent)
        DOWNLOAD_METHOD=2
        shift
        ;;
      --clean-partials)
        CLEAN_PARTIALS=1
        shift
        ;;
      -S | --no-sha)
        CHECKSUM_FILES=0
        shift
        ;;
      -*)
        usage_error "Unknown option: $1"
        ;;
      *)
        # We can either parse the arg here, or just tuck it away for safekeeping
        POSITIONAL_ARGS+=("$1") # save positional arg
        shift                   # past argument
        ;;
    esac
  done

  [[ ${#POSITIONAL_ARGS[@]} -gt 1 ]] && usage_error "Only one ZIM directory can be given, got ${#POSITIONAL_ARGS[@]}: ${POSITIONAL_ARGS[*]}"
  set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters that we skipped earlier

  [[ -t 1 ]] && clear # Clear screen, but only on a terminal (under cron there is no TERM to clear)

  if [[ $CALCULATE_CHECKSUM -ne 0 ]] && [[ $DOWNLOAD_METHOD -ne 1 ]]; then
    echo -e "${RED_BOLD}Calculating Checksum not available with torrenting. Aborting.${CLEAR}" >&2
    exit 2
  fi
  [[ -n "$CountryCodeWarning" ]] && echo -e "${YELLOW_BOLD}$CountryCodeWarning${CLEAR}" >&2

  # Display Header
  echo "=========================================="
  echo " kiwix-zim-updater"
  echo "       download.kiwix.org ZIM Updater"
  echo
  echo "   v$VER by DocDrydenn and jojo2357"
  echo "=========================================="
  echo
  echo "            DRY-RUN/SIMULATION"
  [[ $DEBUG -eq 1 ]] && echo "               - ENABLED -"
  [[ $DEBUG -eq 1 ]] && echo
  [[ $DEBUG -eq 1 ]] && echo "           Use '-d' to disable."
  [[ $DEBUG -eq 0 ]] && echo "               - DISABLED -"
  [[ $DEBUG -eq 0 ]] && echo
  [[ $DEBUG -eq 0 ]] && echo "             !!! Caution !!!"
  echo
  echo "=========================================="
  echo

  check_dependencies
  detect_wget_flavor

  # First, Self-Update Check.
  self_update

  # Second, Flag Check.
  flags "$@"

  # Pick up ZIMs added or removed by hand since the last run (writes only when something changed)
  rebuild_library

  echo
  say "${YELLOW_BOLD}" "3. Processing ZIM(s)..."
  echo

  AnyDownloads=0
  # Set once any download of the run failed: the other ZIMs are still processed, but the script exits 1
  AnyDownloadFailed=0
  # Set once -f found a ZIM it could not verify, or a corrupt one it had to keep: the script exits 1
  AnyVerifyFailed=0
  # .part files of downloads that failed in this run but can be resumed: the cleanup reports them as such
  ResumableParts=()
  # ZIMs that -f verified as good in this run: a .part next to one of them is a replacement that is no longer needed
  VerifiedZIMs=()

  for ((i = 0; i < ${#LocalZIMNameArray[@]}; i++)); do
    RemoteIndex=${LocalZIMRemoteIndexArray[$i]}
    FileName=${LocalZIMNameArray[$i]}
    if [[ $RemoteIndex -eq -1 ]]; then
      if [[ $VERIFY_LIBRARY -eq 1 ]] && [[ -f "$ZIMPath$FileName.sha256" ]]; then
        LocalActionArray+=("$ACT_VERIFY_UNLISTED")
        AnyDownloads=1
        echo -e "${BLUE_BOLD}  - $FileName:${CLEAR}"
        echo -e "${GREEN_REGULAR}    Cached Checksum Found${CLEAR}"
      else
        LocalActionArray+=("$ACT_NONE")
        # Not a ZIM from the catalog (e.g. self-made or renamed) and nothing cached to check it against: outside what
        # -f covers, so say so instead of skipping it silently. This does not change the exit code.
        if [[ $VERIFY_LIBRARY -eq 1 ]]; then
          echo -e "${BLUE_BOLD}  - $FileName:${CLEAR}"
          echo -e "${YELLOW_REGULAR}    Not in the catalog and no cached .sha256: not checked by -f${CLEAR}"
          echo "Not checked by -f: $FileName (not in the catalog, no cached .sha256)" >>"$LOG_FILE"
        fi
      fi
      continue
    fi

    echo -e "${BLUE_BOLD}  - $FileName:${CLEAR}"
    MatchingSize=${FileSizes[$RemoteIndex]}
    MatchingFileName=${RemoteFiles[$RemoteIndex]}
    MatchingCategory=${RemoteCategory[$RemoteIndex]}

    [[ -f "$ZIMPath$MatchingFileName.torrent" ]] && [[ ! -f "$ZIMPath$MatchingFileName" ]] && echo -e "${YELLOW_REGULAR}    Torrent already downloaded\n${GREEN_BOLD}    ✓ Online Version Found${CLEAR}\n" && LocalActionArray+=("$ACT_NONE") && continue

    MatchedDate="$(zim_date "$MatchingFileName")"
    LocalDate="$(zim_date "$FileName")"

    FileTooSmall=0
    [[ $MIN_SIZE -gt 0 ]] && [[ $MatchingSize -lt $MIN_SIZE ]] && FileTooSmall=1
    FileTooLarge=0
    [[ $MAX_SIZE -gt 0 ]] && [[ $MatchingSize -gt $MAX_SIZE ]] && FileTooLarge=1
    FileSizeAcceptable=0
    [ $FileTooSmall -eq 0 ] && [ $FileTooLarge -eq 0 ] && FileSizeAcceptable=1

    # A locked ZIM is an interrupted download to finish. With -f only the current catalog version can be finished; an
    # outdated one is verified against its own checksum like any other outdated ZIM below. The -n/-x limits apply to
    # finishing it too: outside them it is left alone (and kept) for a run that allows its size.
    if [[ -f "$ZIMPath.~lock.$FileName" ]] && { [[ $VERIFY_LIBRARY -eq 0 ]] || [[ "$MatchingFileName" == "$FileName" ]]; }; then
      if [[ $FileSizeAcceptable -eq 0 ]]; then
        LocalActionArray+=("$ACT_NONE")
        echo -e "${YELLOW_REGULAR}    Incomplete download detected, but $(numfmt --to=iec-i "$MatchingSize") is outside the -n/-x size limits. Left as it is.${CLEAR}\n"
        echo "Incomplete download of $FileName left as it is: outside the -n/-x size limits" >>"$LOG_FILE"
      else
        echo -e "${YELLOW_REGULAR}    Incomplete download detected\n${GREEN_BOLD}    ✓ Online Version Found${CLEAR}\n"
        LocalActionArray+=("$ACT_UPDATE")
        AnyDownloads=1
      fi
      continue
    fi

    if [ $VERIFY_LIBRARY -eq 1 ] && [ $FileSizeAcceptable -eq 0 ]; then
      if [ $FileTooSmall -eq 1 ]; then
        LocalActionArray+=("$ACT_NONE")
        [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Verification skipped due to file size (minimum: $(numfmt --to=iec-i "$MIN_SIZE"), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
        [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Verification skipped due to file size (minimum: $(numfmt --to=iec-i "$MIN_SIZE"), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
      elif [ $FileTooLarge -eq 1 ]; then
        LocalActionArray+=("$ACT_NONE")
        [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Verification skipped due to file size (maximum: $(numfmt --to=iec-i "$MAX_SIZE"), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
        [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Verification skipped due to file size (maximum: $(numfmt --to=iec-i "$MAX_SIZE"), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
      fi
    elif [[ "$MatchingFileName" == "$FileName" ]]; then
      if [ $VERIFY_LIBRARY -eq 1 ]; then
        LocalActionArray+=("$ACT_UPDATE")
        AnyDownloads=1
        echo -e "${GREEN_BOLD}    ✓ Online Version Found${CLEAR}"
      else
        LocalActionArray+=("$ACT_NONE")
        echo "    ✗ No new update"
      fi
    else
      if [ $VERIFY_LIBRARY -eq 1 ]; then
        if [[ -f "$ZIMPath$FileName.sha256" ]]; then
          LocalActionArray+=("$ACT_VERIFY_CACHED")
          AnyDownloads=1
          echo -e "${GREEN_REGULAR}    Cached Checksum Found${CLEAR}"
        else
          echo "    Checking for online checksum..."
          if wget "${WGET_NET_OPTS[@]}" -S --spider -q -O - "$BaseURL$MatchingCategory/$FileName.sha256" >/dev/null 2>&1; then
            LocalActionArray+=("$ACT_VERIFY_ONLINE")
            AnyDownloads=1
            echo -e "${GREEN_BOLD}    ✓ Online Version Found${CLEAR}"
          else
            LocalActionArray+=("$ACT_NONE")
            # Nothing to verify it against: the file is kept, but the verification failed (exit 1)
            echo "    ✗ Online Version Not Found"
            echo -e "${YELLOW_BOLD}    No checksum for $FileName anywhere, it cannot be verified. Kept; a normal update run replaces it with the newer version.${CLEAR}"
            echo "Cannot verify $FileName: no checksum available locally or online. Kept." >>"$LOG_FILE"
            AnyVerifyFailed=1
          fi
        fi
      else
        if [ $FileTooSmall -eq 1 ]; then
          LocalActionArray+=("$ACT_NONE")
          [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Update skipped (minimum: $(numfmt --to=iec-i "$MIN_SIZE"), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $MatchedDate${CLEAR}"
          [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Update skipped (minimum: $(numfmt --to=iec-i "$MIN_SIZE"), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $MatchedDate${CLEAR}"
        elif [ $FileTooLarge -eq 1 ]; then
          LocalActionArray+=("$ACT_NONE")
          [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Update skipped (maximum: $(numfmt --to=iec-i "$MAX_SIZE"), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $MatchedDate${CLEAR}"
          [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Update skipped (maximum: $(numfmt --to=iec-i "$MAX_SIZE"), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $MatchedDate${CLEAR}"
        elif ! zim_is_newer "$MatchedDate" "$LocalDate"; then
          LocalActionArray+=("$ACT_NONE")
          echo "    ✗ No new update"
        else
          LocalActionArray+=("$ACT_UPDATE")
          AnyDownloads=1
          echo -e "${GREEN_BOLD}    ✓ Update found! --> $MatchedDate${CLEAR}"
        fi
      fi
    fi
    echo
  done

  say "${YELLOW_BOLD}" "4. Downloading New ZIM(s)..."
  echo


  # Let's Start the download process, but only if we have actual downloads to do.
  if [ $AnyDownloads -eq 1 ]; then
    for ((z = 0; z < ${#LocalZIMNameArray[@]}; z++)); do # Iterate through the download queue.
      Action=${LocalActionArray[$z]}
      [[ $Action -eq $ACT_NONE ]] && continue

      # Per-file state: nothing may carry over from the previous ZIM (or leak in from the environment)
      DownloadFailed=0
      IsMirror=0
      DownloadURL=""
      ExpectedSize=""
      ExpectedHash=""
      HashFromCache=0 # set when -f verifies against the cached .sha256 because the metadata is unavailable

      OldZIM=${LocalZIMNameArray[$z]}
      OldZIMPath=$ZIMPath$OldZIM

      echo -e "${BLUE_BOLD}  Processing $OldZIM${CLEAR}"

      if [[ $Action -eq $ACT_VERIFY_CACHED ]] || [[ $Action -eq $ACT_VERIFY_UNLISTED ]]; then
        # Verified against its own cached checksum only: no metadata, no download
        ExpectedHash=$(grep -ioP "^[0-9a-f]{64}" <"$OldZIMPath.sha256")

        NewZIM="$OldZIM"
        NewZIMPath="$OldZIMPath"
      elif [[ $Action -eq $ACT_VERIFY_ONLINE ]]; then
        # Outdated ZIM: verify it against its own published checksum, not against the newer release's meta4
        ExpectedHash=$(wget "${WGET_NET_OPTS[@]}" -q -O - "$BaseURL${RemoteCategory[${LocalZIMRemoteIndexArray[$z]}]}/$OldZIM.sha256" 2>/dev/null | grep -ioP "^[0-9a-f]{64}")

        NewZIM="$OldZIM"
        NewZIMPath="$OldZIMPath"
      else
        mirror_search # Let's look for a mirror URL first.

        # -f without metadata (offline, or the meta4 fetch failed): fall back to the checksum stored on an earlier run
        if [[ $VERIFY_LIBRARY -eq 1 ]] && ! [[ "$ExpectedHash" =~ ^[0-9a-fA-F]{64}$ ]] && [[ -f "$OldZIMPath.sha256" ]]; then
          ExpectedHash=$(grep -ioP "^[0-9a-f]{64}" <"$OldZIMPath.sha256")
          HashFromCache=1
          echo -e "${YELLOW_REGULAR}    Metadata unavailable, verifying against the cached checksum${CLEAR}"
          echo "Metadata unavailable for $OldZIM, verifying against the cached checksum" >>"$LOG_FILE"
        fi

        NewZIM=${RemoteFiles[${LocalZIMRemoteIndexArray[$z]}]}
        NewZIMPath=$ZIMPath$NewZIM
      fi


      FilePath=$ZIMPath$NewZIM              # Set destination path with file name
      LockFilePath="$ZIMPath.~lock.$NewZIM" # Set destination path with file name
      TorrentFilePath="$ZIMPath$NewZIM.torrent" # Set destination path with file name
      # Web downloads go into a .part file and only get the ZIM's name once they passed every check, so kiwix-serve
      # (and this script) never see an unverified file under a .zim name
      PartPath="$ZIMPath$NewZIM.part"
      DownloadTarget=""

      RequiresDownload=0

      if [ $VERIFY_LIBRARY -eq 0 ]; then
        if [[ $DOWNLOAD_METHOD -eq 2 ]]; then
          if [[ -f "$NewZIMPath" ]]; then
            [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : ZIM already exists on disk. Skipping download.${CLEAR}"
            [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  ZIM already exists on disk. Skipping download.${CLEAR}"
            echo
          elif [[ -f $TorrentFilePath ]]; then
            [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : Torrent already exists on disk. Skipping download.${CLEAR}"
            [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  Torrent already exists on disk. Skipping download.${CLEAR}"
            echo
          else
            [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : Torrent doesn't exist on disk. Downloading...${CLEAR}"
            [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  Torrent doesn't exist on disk. Downloading...${CLEAR}"
            RequiresDownload=1
          fi
        elif [[ -f "$NewZIMPath" ]] && ! [[ -f "$LockFilePath" ]]; then # New ZIM already found, and no interruptions, we don't need to download it.
          [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : ZIM already exists on disk. Skipping download.${CLEAR}"
          [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  ZIM already exists on disk. Skipping download.${CLEAR}"
          echo
        else # New ZIM not found, so we'll go ahead and download it.
          RequiresDownload=1
          if [[ -f $LockFilePath ]] || [[ -f "$PartPath" ]]; then
            [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : ZIM download was interrupted. Continuing...${CLEAR}"
            [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  ZIM download was interrupted. Continuing...${CLEAR}"
          else
            [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : ZIM doesn't exist on disk. Downloading...${CLEAR}"
            [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  ZIM doesn't exist on disk. Downloading...${CLEAR}"
          fi
          echo
        fi
      else
        # lockfile implies an incomplete download (only the current catalog version, state 1, is ever downloaded)
        if [[ $Action -eq $ACT_UPDATE ]] && [[ -f $LockFilePath ]]; then
          echo "Incomplete download detected, resuming" >>"$LOG_FILE"
          echo -e "${YELLOW_REGULAR}    Status: Incomplete download detected, resuming${CLEAR}"

          RequiresDownload=1
        elif [[ $Action -eq $ACT_UPDATE ]] && [[ -f $TorrentFilePath ]]; then
          echo -e "${YELLOW_REGULAR}    Status: Torrent exists, skipping${CLEAR}"
          echo "Skipping checksum for torrent : $OldZIM. If the download has been completed, please delete the .torrent if you want me to verify the checksum." >>"$LOG_FILE"
        else
          # actually verify the file
          say "${BLUE_REGULAR}" "    Calculating checksum for : $OldZIM"
          { [[ $Action -eq $ACT_UPDATE ]] || [[ $Action -eq $ACT_VERIFY_ONLINE ]]; } && write_checksum_file "$OldZIM" "$ExpectedHash"
          # An unknown expected size (failed meta4 fetch) is "cannot verify", never "corrupt"
          if [[ $Action -eq $ACT_UPDATE ]] && [[ "$ExpectedSize" =~ ^[0-9]+$ ]] && [[ $(du -b "$OldZIMPath" | grep -ioP "^\d+") -ne "$ExpectedSize" ]]; then
            RequiresDownload=1
            if [[ $DEBUG -eq 0 ]]; then
              if [[ $SKIP_PURGE -eq 0 ]]; then
                # The corrupt file stays until its replacement is verified (it is downloaded into a .part file)
                say "${RED_BOLD}" "    ✗ Status : File size verification failed, downloading a replacement"
              else
                say "${RED_BOLD}" "    ✗ Status : File size verification failed but purge skipped"
                AnyVerifyFailed=1
              fi
            else
              [[ $SKIP_PURGE -eq 0 ]] && echo -e "${RED_BOLD}    ✗ Status : *** Simulated *** File size verification failed, a replacement would be downloaded ($FilePath)${CLEAR}"
              [[ $SKIP_PURGE -eq 1 ]] && echo -e "${RED_BOLD}    ✗ Status : *** Simulated *** File size verification failed but purge skipped ($FilePath)${CLEAR}"
              # The dry-run keeps the corrupt file: that is a failed verification, like any corrupt ZIM that is kept
              AnyVerifyFailed=1
            fi
            # With -p the corrupt file stays where it is, so there is nothing to download into its place
            if [[ $SKIP_PURGE -eq 1 ]]; then
              echo
              continue
            fi

            echo
          elif [[ ${#ExpectedHash} -ne 64 ]]; then
            echo -e "${YELLOW_BOLD}    No valid checksum available (metadata unavailable?), cannot verify $OldZIM. Skipping, file kept.${CLEAR}" && echo "Cannot verify $OldZIM: no valid checksum available, file kept" >>"$LOG_FILE"
            AnyVerifyFailed=1
          elif ! hash_matches "$OldZIM" "$ExpectedHash"; then
            # we checked a very old file, but we will choose to not replace it because we cannot, so we will leave it. A regular update will purge it naturally
            if [[ $Action -eq $ACT_VERIFY_UNLISTED ]]; then
              echo -e "${RED_BOLD}    ✗ Checksum failed, but no online version to replace it with. File kept.${CLEAR}"
              echo "✗ Checksum failed for $OldZIM, no online version to replace it with. File kept." >>"$LOG_FILE"
              AnyVerifyFailed=1
              echo
              continue
            elif [[ $Action -ne $ACT_UPDATE ]]; then
              echo -e "${RED_BOLD}    ✗ Checksum failed. File kept; a normal update run (without -f) will replace it with the newer version.${CLEAR}"
              echo "✗ Checksum failed for $OldZIM. File kept; a normal update run will replace it with the newer version." >>"$LOG_FILE"
              AnyVerifyFailed=1
              echo
              continue
            elif [[ $HashFromCache -eq 1 ]]; then
              # Without metadata a replacement could not be verified, so deleting the file would only lose it
              echo -e "${RED_BOLD}    ✗ Checksum failed against the cached checksum. File kept: without metadata no replacement can be verified now.${CLEAR}"
              echo "✗ Checksum failed for $OldZIM against the cached checksum. File kept: without metadata no replacement can be verified now." >>"$LOG_FILE"
              AnyVerifyFailed=1
              echo
              continue
            fi
            if [[ $DEBUG -eq 0 ]]; then
              if [[ $SKIP_PURGE -eq 0 ]]; then
                # The corrupt file stays until its replacement is verified (it is downloaded into a .part file)
                say "${RED_BOLD}" "    ✗ Status : Checksum failed, downloading a replacement"
              else
                say "${RED_BOLD}" "    ✗ Status : Checksum failed but purge was skipped"
                AnyVerifyFailed=1
                echo
                continue
              fi
            else
              [[ $SKIP_PURGE -eq 0 ]] && echo -e "${RED_BOLD}    ✗ Status : *** Simulated *** Checksum failed, a replacement would be downloaded ($FilePath)${CLEAR}"
              [[ $SKIP_PURGE -eq 1 ]] && echo -e "${RED_BOLD}    ✗ Status : *** Simulated *** Checksum failed but purge was skipped ($FilePath)${CLEAR}"
              # The dry-run keeps the corrupt file: that is a failed verification, like any corrupt ZIM that is kept
              AnyVerifyFailed=1
            fi

            RequiresDownload=1
            echo
          else
            say "${GREEN_BOLD}" "    ✓ Status : Checksum passed"
            VerifiedZIMs+=("$OldZIM")

            [[ $DEBUG -eq 0 ]] && echo "End : $(date -u)" >>"$LOG_FILE"
            [[ $DEBUG -eq 1 ]] && echo "End : $(date -u) *** Simulation ***" >>"$LOG_FILE"


            echo
            continue
          fi
          # Verified against its own checksum only (states 2, 3 and 4): there is nothing to download
          [[ $Action -ne $ACT_UPDATE ]] && continue
        fi
      fi
      echo >>"$LOG_FILE"
      [[ $DEBUG -eq 0 ]] && echo "Start : $(date -u)" >>"$LOG_FILE"
      [[ $DEBUG -eq 1 ]] && echo "Start : $(date -u) *** Simulation ***" >>"$LOG_FILE"
      # Here is where we actually download the files and log to the download.log file.
      if [[ $RequiresDownload -eq 1 ]]; then
        [[ $IsMirror -eq 0 ]] && echo -e "${BLUE_REGULAR}    Download (direct) : $DownloadURL${CLEAR}"
        [[ $IsMirror -eq 1 ]] && echo -e "${BLUE_REGULAR}    Download (mirror) : $DownloadURL${CLEAR}"

        {
          echo
          echo "======================================================================="
          echo "File : $NewZIM"
          [[ $IsMirror -eq 0 ]] && echo "URL (direct) : $DownloadURL"
          [[ $IsMirror -eq 1 ]] && echo "URL (mirror) : $DownloadURL"
          echo
        } >>"$LOG_FILE"

        if [[ $DOWNLOAD_METHOD -eq 2 ]]; then
          FilePath="$FilePath.torrent"
          if [[ -f "$LockFilePath" ]]; then
            [[ $DEBUG -eq 0 ]] && { download_file "$FilePath" "$DownloadURL" || DownloadFailed=1; } # Download new ZIM
            [[ $DEBUG -eq 1 ]] && echo "Continue Download : $FilePath" >>"$LOG_FILE"
          elif [[ -f $FilePath ]]; then # New ZIM already found, we don't need to download it.
            [[ $DEBUG -eq 1 ]] && echo "Download : New Torrent already exists on disk. Skipping download." >>"$LOG_FILE"
          else # New ZIM not found, so we'll go ahead and download it.
            [[ $DEBUG -eq 0 ]] && { download_file "$FilePath" "$DownloadURL" || DownloadFailed=1; } # Download new ZIM
            [[ $DEBUG -eq 1 ]] && echo "Download : $FilePath" >>"$LOG_FILE"
          fi

          if [[ $DownloadFailed -eq 1 ]]; then
            AnyDownloadFailed=1
            # wget leaves a partial or empty .torrent behind, which would be mistaken for a finished one next run
            rm -f "$FilePath"
            say "${RED_BOLD}" "    ✗ Status : Torrent download failed"
            echo " !!! DOWNLOAD FAILED !!!" >>"$LOG_FILE"
            echo
          fi
          continue
        else
          DownloadTarget="$PartPath"
          if [[ -f "$LockFilePath" ]]; then
            # A `.~lock.` marker comes from an older version of this script, which downloaded straight into the ZIM's
            # name. Next to another version of the same ZIM the locked file becomes a .part file. A lone one (no other
            # version) stays where it is, so the ZIM stays in the listing: if it already has the published size it is
            # verified in place, otherwise the replacement is downloaded into .part and renamed over it once verified.
            # Nothing is ever written into the locked file itself (Wget2 would append to it when a server ignores the
            # range request).
            if [[ -f "$NewZIMPath" ]] && ! other_local_version_exists "${Basenames[${LocalZIMRemoteIndexArray[$z]}]}" "$NewZIM"; then
              if [[ "$ExpectedSize" =~ ^[0-9]+$ ]] && [[ $(stat -c %s "$NewZIMPath") -eq $ExpectedSize ]] && [[ ! -e "$PartPath" ]]; then
                DownloadTarget="$NewZIMPath"
              fi
            elif [[ $DEBUG -eq 0 ]]; then
              if [[ -f "$NewZIMPath" ]] && [[ ! -e "$PartPath" ]]; then
                mv -f "$NewZIMPath" "$PartPath" && echo "Moved interrupted download $NewZIMPath to $PartPath" >>"$LOG_FILE"
              fi
              [[ ! -f "$NewZIMPath" ]] && rm -f "$LockFilePath"
            fi
          fi
          if [[ "$ExpectedSize" =~ ^[0-9]+$ ]] && [[ -f "$DownloadTarget" ]] && [[ $(stat -c %s "$DownloadTarget") -gt $ExpectedSize ]] && \
            [[ "$DownloadTarget" == "$PartPath" ]]; then
            # A partial that is larger than published cannot be resumed: start over
            echo -e "${YELLOW_REGULAR}    Status : $PartPath is larger than published, starting the download over${CLEAR}"
            echo "$PartPath is larger than published, starting the download over" >>"$LOG_FILE"
            [[ $DEBUG -eq 0 ]] && rm -f "$PartPath"
          fi
          # Before fetching anything: without the published size the download could never be verified, and it must
          # not fill the file system that also holds the library (keep --min-free free afterwards)
          SpaceProblem=""
          if ! [[ "$ExpectedSize" =~ ^[0-9]+$ ]]; then
            SpaceProblem="metadata unavailable, the download could not be verified"
          elif ! [[ -f "$DownloadTarget" && $(stat -c %s "$DownloadTarget") -eq $ExpectedSize ]]; then
            AlreadyHave=0
            [[ -f "$DownloadTarget" ]] && [[ "$DownloadTarget" == "$PartPath" ]] && AlreadyHave=$(stat -c %s "$DownloadTarget")
            Available=$(free_bytes "$ZIMPath")
            if [[ "$Available" =~ ^[0-9]+$ ]] && [[ $((Available - (ExpectedSize - AlreadyHave))) -lt $MIN_FREE ]]; then
              SpaceProblem="not enough free space: it needs $(numfmt --to=iec-i $((ExpectedSize - AlreadyHave))), $(numfmt --to=iec-i "$Available") is available and $(numfmt --to=iec-i "$MIN_FREE") must stay free (--min-free)"
            fi
          fi
          if [[ -n "$SpaceProblem" ]]; then
            if [[ $DEBUG -eq 0 ]]; then
              echo -e "${RED_BOLD}    ✗ Status : Download skipped, $SpaceProblem. Old ZIM kept.${CLEAR}"
              echo "✗ Status : Download of $NewZIM skipped, $SpaceProblem. Old ZIM kept." >>"$LOG_FILE"
              DownloadFailed=1
            else
              echo -e "${YELLOW_BOLD}    *** Simulated *** The download would be skipped: $SpaceProblem${CLEAR}"
            fi
          elif [[ "$ExpectedSize" =~ ^[0-9]+$ ]] && [[ -f "$DownloadTarget" ]] && [[ $(stat -c %s "$DownloadTarget") -eq $ExpectedSize ]]; then
            # The interrupted download is already complete (e.g. the run was killed while hashing it). Do not ask wget
            # to resume it: Wget2 appends the whole body again when a server ignores the range request. Just verify it.
            echo -e "${GREEN_REGULAR}    ✓ Status : Interrupted download is already complete, verifying it${CLEAR}"
            echo "Interrupted download is already complete, verifying it : $DownloadTarget" >>"$LOG_FILE"
          elif [[ -f "$DownloadTarget" ]]; then
            [[ $DEBUG -eq 0 ]] && { download_file "$DownloadTarget" "$DownloadURL" || DownloadFailed=1; } # Resume
            [[ $DEBUG -eq 1 ]] && echo "Continue Download : $DownloadTarget" >>"$LOG_FILE"
          else
            [[ $DEBUG -eq 0 ]] && { download_file "$DownloadTarget" "$DownloadURL" || DownloadFailed=1; } # Download new ZIM
            [[ $DEBUG -eq 1 ]] && echo "Download : $DownloadTarget" >>"$LOG_FILE"
          fi
        fi
      fi

      # The file to verify: what this run downloaded (a .part file, or a lone legacy download finished in place), or
      # the new ZIM that was already on disk
      CheckPath="$NewZIMPath"
      [[ -n "$DownloadTarget" ]] && CheckPath="$DownloadTarget"
      CheckName="${CheckPath##*/}"

      [[ $DEBUG -eq 0 ]] && [[ $DownloadFailed -eq 1 ]] && say "${RED_BOLD}" "    ✗ Status : Download failed"

      # Never purge on an unverified file: whatever we downloaded, or are about to replace the old ZIM with, must match
      # the size published in the meta4. The catalog length is rounded to whole KiB, so it is no substitute.
      if [[ $DEBUG -eq 0 ]] && [[ $DownloadFailed -ne 1 ]] && { [[ $RequiresDownload -eq 1 ]] || [[ $VERIFY_LIBRARY -eq 0 ]]; }; then
        ActualSize=$(stat -c %s "$CheckPath" 2>/dev/null)
        if ! [[ "$ExpectedSize" =~ ^[0-9]+$ ]]; then
          say "${RED_BOLD}" "    ✗ Status : Expected size unknown (metadata unavailable), cannot verify $NewZIM"
          DownloadFailed=1
        elif [[ "$ActualSize" != "$ExpectedSize" ]]; then
          say "${RED_BOLD}" "    ✗ Status : File size verification failed (expected $ExpectedSize, found ${ActualSize:-no file})"
          DownloadFailed=1
        fi
      fi

      # In -f mode a file that was not (re-)downloaded has already been verified above
      if [[ $CALCULATE_CHECKSUM -eq 1 ]] && [[ $DownloadFailed -ne 1 ]] && { [[ $RequiresDownload -eq 1 ]] || [[ $VERIFY_LIBRARY -eq 0 ]]; }; then
        echo -e "${BLUE_REGULAR}    Calculating checksum for : $CheckPath${CLEAR}"
        # The size was already verified above for every real download; the checksum is what -c adds
        if ! [[ "$ExpectedHash" =~ ^[0-9a-fA-F]{64}$ ]]; then
          # -c promises a checksum-verified replacement: without a published sha256 the old ZIM must stay
          if [[ $DEBUG -eq 0 ]]; then
            say "${RED_BOLD}" "    ✗ No valid sha256 published for $NewZIM, cannot verify its checksum. Old ZIM kept."
            DownloadFailed=1
          else
            echo -e "${YELLOW_BOLD}    *** Simulated *** No valid sha256 published for $NewZIM, the checksum could not be verified${CLEAR}"
          fi
        elif [[ $DEBUG -eq 1 ]]; then
          echo -e "${GREEN_BOLD}    ✓ *** Simulated *** Checksum passed${CLEAR}"
        elif ! hash_matches "$CheckName" "$ExpectedHash"; then
          if [[ "$CheckPath" == "$NewZIMPath" ]] && [[ -f "$LockFilePath" ]]; then
            # A lone locked file of an older version of this script: keep it (it is the only copy of this ZIM) and turn
            # it into a normal ZIM, so that -f replaces it the usual way, verified before anything is removed
            echo -e "${RED_BOLD}    ✗ Checksum failed for $NewZIM. It is kept; run with -f to replace it with a verified download.${CLEAR}"
            echo "✗ Checksum failed for $NewZIM (old-style interrupted download). Kept; run with -f to replace it." >>"$LOG_FILE"
            rm -f "$LockFilePath"
          else
            echo -e "${RED_BOLD}    ✗ Checksum failed, removing corrupt download${CLEAR}"
            echo "✗ Checksum failed, removing corrupt download $CheckPath" >>"$LOG_FILE"
            rm -f "$CheckPath"
          fi
          DownloadFailed=1
        else
          echo -e "${GREEN_BOLD}    ✓ Checksum passed${CLEAR}"
        fi
        echo
      fi

      # A verified .part file gets the ZIM's name (in -f mode this atomically replaces the corrupt file)
      if [[ $DEBUG -eq 0 ]] && [[ $DownloadFailed -ne 1 ]] && [[ "$CheckPath" == "$PartPath" ]]; then
        if mv -f "$PartPath" "$NewZIMPath"; then
          echo "Verified $PartPath, renamed to $NewZIMPath" >>"$LOG_FILE"
          # List the new ZIM before the old one is purged, so kiwix-serve never lacks this title
          rebuild_library
        else
          say "${RED_BOLD}" "    ✗ Status : Could not rename $PartPath to $NewZIMPath"
          DownloadFailed=1
        fi
      fi

      # Only a file that passed every check gets a checksum file
      [[ $DownloadFailed -ne 1 ]] && write_checksum_file "$NewZIM" "$ExpectedHash"

      echo >> "$LOG_FILE"
      [[ $DownloadFailed -eq 1 ]] && echo " !!! DOWNLOAD FAILED !!!" >>"$LOG_FILE"
      [[ $DownloadFailed -eq 1 ]] && AnyDownloadFailed=1
      # A failed .part download is resumed with wget -c next run, unless it is larger than published (it cannot be)
      if [[ $DownloadFailed -eq 1 ]] && [[ $DEBUG -eq 0 ]] && [[ "$CheckPath" == "$PartPath" ]] && [[ -f "$PartPath" ]]; then
        if [[ "$ExpectedSize" =~ ^[0-9]+$ ]] && [[ $(stat -c %s "$PartPath") -gt $ExpectedSize ]]; then
          say "${RED_BOLD}" "    ✗ Removing $PartPath: it is larger than published and cannot be resumed"
          rm -f "$PartPath"
        else
          ResumableParts+=("$PartPath")
        fi
      fi

      # In all of these cases nothing is purged: a failed download stays in its .part file to be resumed next run
      if [[ $DownloadFailed -eq 1 ]] || [[ $SKIP_PURGE -eq 1 ]] || [[ $VERIFY_LIBRARY -eq 1 ]]; then
        [[ $DEBUG -eq 0 ]] && echo "End : $(date -u)" >>"$LOG_FILE"
        [[ $DEBUG -eq 1 ]] && echo "End : $(date -u) *** Simulation ***" >>"$LOG_FILE"
        [[ $DEBUG -eq 0 ]] && [[ $SKIP_PURGE -eq 1 ]] && [[ $DownloadFailed -ne 1 ]] && rm -f "$LockFilePath"
        [[ $DEBUG -eq 0 ]] && [[ $VERIFY_LIBRARY -eq 1 ]] && [[ $RequiresDownload -eq 1 ]] && [[ $DownloadFailed -ne 1 ]] && rm -f "$LockFilePath"
        continue
      fi

      [[ $RequiresDownload -eq 1 ]] && [[ $DEBUG -eq 0 ]] && rm -f "$LockFilePath"

      ########################################

      say "${BLUE_REGULAR}" "    Old : $OldZIM"
      say "${BLUE_BOLD}" "    New : $NewZIM"
      # Check for the new ZIM on disk.
      if [[ -f "$NewZIMPath" ]]; then # New ZIM found
        if [[ $DEBUG -eq 0 ]]; then
          if [[ "$OldZIMPath" == "$NewZIMPath" ]]; then
            say "${GREEN_BOLD}" "    ✓ Status : New ZIM downloaded successfully."
          else
            say "${GREEN_BOLD}" "    ✓ Status : New ZIM downloaded successfully. Old ZIM purged."
            [[ -f "$OldZIMPath" ]] && rm "$OldZIMPath" && rm "$OldZIMPath.sha256" 2>/dev/null # Purge old ZIM
            rebuild_library
          fi
        else
          say "${GREEN_BOLD}" "    ✓ Status : *** Simulated ***"
        fi
      else # New ZIM not found. Something went wrong, so we will skip this purge.
        if [[ $DEBUG -eq 0 ]]; then
          say "${RED_BOLD}" "    ✗ Status : New ZIM failed verification. Old ZIM not purged."
        else
          if [[ $RequiresDownload -eq 1 ]]; then
            say "${GREEN_BOLD}" "    ✓ Status : *** Simulated *** New zim exists, old zim purged"
          else
            echo -e "${YELLOW_BOLD}    ✗ Status : *** Simulated *** Zim was skipped, and will not be purged${CLEAR}"
            echo "✗ Status : *** Simulated *** Zim not purged" >>"$LOG_FILE"
          fi
        fi
      fi
      echo
      echo >>"$LOG_FILE"

      #########################################

      [[ $DEBUG -eq 0 ]] && echo "End : $(date -u)" >>"$LOG_FILE"
      [[ $DEBUG -eq 1 ]] && echo "End : $(date -u) *** Simulation ***" >>"$LOG_FILE"
    done

  else
    say "${GREEN_REGULAR}" "    ✓ Download: Nothing to download."
    echo
  fi

  cleanup_partials
  # Anything else that changed the set of finished ZIMs (e.g. an old-style lock that was resolved)
  rebuild_library

  if [[ $LibraryFailed -eq 1 ]]; then
    echo -e "${RED_BOLD}✗ The library file $LIBRARY_XML could not be fully updated, see $LOG_FILE${CLEAR}"
    echo "✗ The library file $LIBRARY_XML could not be fully updated" >> "$LOG_FILE"
  fi
  if [[ $AnyDownloadFailed -eq 1 ]]; then
    echo -e "${RED_BOLD}✗ One or more downloads failed, see $LOG_FILE${CLEAR}"
    echo "✗ One or more downloads failed" >> "$LOG_FILE"
    exit 1
  fi
  if [[ $ForcedDryRun -eq 1 ]]; then
    say "${RED_BOLD}" "✗ -d was given but the ZIM directory is not writable, so nothing was changed"
    exit 1
  fi
  if [[ $AnyVerifyFailed -eq 1 ]]; then
    echo -e "${RED_BOLD}✗ One or more ZIMs could not be verified or failed verification and were kept, see $LOG_FILE${CLEAR}"
    echo "✗ One or more ZIMs could not be verified or failed verification and were kept" >> "$LOG_FILE"
    exit 1
  fi
  [[ $LibraryFailed -eq 1 ]] && exit 1
  exit 0
}

# Run only when executed; when sourced (e.g. by the unit tests) just define the functions and defaults
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
