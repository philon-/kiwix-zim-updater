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
# This array is a boolean array which remembers if a given local zim should be processed in the download loop
LocalRequiresDownloadArray=()
# After updating, this array will be used to store hanging locks and to deal with them
HangingFileLocks=();

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
CALLEDSCRIPTNAME="$0"
CALLEDSCRIPTFILE="$(basename "$CALLEDSCRIPTNAME")"
CALLEDSCRIPTPATH="$(dirname "$CALLEDSCRIPTNAME")"
ARGS=("$@")
BRANCH="main"
SKIP_UPDATE=0
DEBUG=1 # This forces the script to default to "dry-run/simulation mode"
MIN_SIZE=0
MAX_SIZE=0
CALCULATE_CHECKSUM=0
CHECKSUM_FILES=1
VERIFY_LIBRARY=0
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
# Extra wget options for .meta4 requests. GNU Wget2 follows metalinks by default and would hand us the ZIM itself
# instead of the metadata; wget 1.x rejects --no-metalink, so this is filled in by detect_wget_flavor.
WGET_META_OPTS=()
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
    if [[ -z "${indexDate}" ]] || [[ "$(date -u -d "$indexDate" +%s)" -lt "$(date -u -d "1 day ago" +%s)" ]]; then
      indexIsValid=0
    fi
  fi

  if [[ FORCE_FETCH_INDEX -eq 1 ]] || [[ $indexIsValid -eq 0 ]]; then
    # both write the file timestamp to the index file and save all of the links to RawLibrary.
    # Lets defer touching the index until we have actually fetched it
    RawLibrary="$(wget --show-progress -q -O - "$CatalogURL")"
    RawLibrary="$(echo "$RawLibrary" | tee --output-error=warn-nopipe >(grep -ioP "(?<=<updated>)\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?=Z</updated>)" | head -1 > "$INDEX_FILE") | grep -i 'application/x-zim' | grep -ioP "^\s+\K.*$")"
    echo "$RawLibrary" >> "$INDEX_FILE"
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
  # these probably arent gonna be a problem so we will ignore them
#  ValidLibrary="$(echo "$ValidLibrary" | grep -iP "$REMOTE_PATH_REGEX")"
#  ValidLibrary="$(echo "$ValidLibrary" | grep -iP "$REMOTE_CATEGORY_REGEX")"

  IFS=$'\n' read -r -d '' -a FileSizes < <(echo "$ValidLibrary" | grep -ioP '(?<=length=")\d+(?=")')
  unset IFS

  RawLinks=$(echo "$ValidLibrary" | grep -ioP "(?<=href=\")[\w:\/\-.]+(?=\.meta4\")")

  BaseURL=$(echo "$RawLinks" | grep -ioP 'https?://[^/]+' | uniq)

  FoundURLs=$(echo "$BaseURL" | wc -l)

  if [[ -z "$BaseURL" ]]; then
    echo -e "${RED_REGULAR}  ✗ No ZIM URLs found. Exiting...${CLEAR}"
    exit 0
  elif [[ $FoundURLs -ne 1 ]]; then
    echo -e "${RED_REGULAR}  ✗ Too many zim base urls found. Please open an issue on github. Exiting...${CLEAR}"
    exit 0
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
    echo -e "${RED_REGULAR}    ✗  Could not find any remote files, exiting${CLEAR}"
    echo "✗  Could not find any remote files, exiting" >> "$LOG_FILE"
    exit 0
  else
    echo -e "${GREEN_BOLD}    ✓ Found ${#RemoteFiles[@]} files online"
    echo "✓ Found ${#RemoteFiles[@]} files online" >> "$LOG_FILE"
  fi

  if [[ ${#RemoteFiles[@]} -ne ${#RemoteFiles[@]} ]] || \
    [[ ${#RemoteFiles[@]} -ne ${#Basenames[@]} ]] || \
    [[ ${#RemoteFiles[@]} -ne ${#RemotePaths[@]} ]] || \
    [[ ${#RemoteFiles[@]} -ne ${#RemoteCategory[@]} ]] || \
    [[ ${#RemoteFiles[@]} -ne ${#FileSizes[@]} ]] ; then
    echo -e "${RED_BOLD}CRITICAL ERROR!${CLEAR}"
    echo -e "${RED}Parsed array lengths did not match. Aborting to prevent data loss${CLEAR}"
    exit 99
  fi

  # Housekeeping...
  unset ValidLibrary
  unset RawLibrary
  unset hrefs
}

# self_update - Script Self-Update Function
self_update() {
  echo -e "${YELLOW_BOLD}1. Checking for Script Updates...${CLEAR}"
  echo  "1. Checking for Script Updates..." >> "$LOG_FILE"
  echo
  # Check if script path is a git clone.
  #   If true, then check for update.
  #   If false, skip self-update check/function.
  if [ $SKIP_UPDATE -eq 1 ]; then
    echo -e "${YELLOW_REGULAR}   Check Skipped${CLEAR}"
    echo "Check Skipped" >> "$LOG_FILE"
  elif [[ -d "$SCRIPTPATH/.git" ]]; then
    echo -e "${GREEN_BOLD}   ✓ Git Clone Detected: Checking Script Version...${CLEAR}"
    echo "✓ Git Clone Detected: Checking Script Version..." >> "$LOG_FILE"
    [[ $(timeout 1s git -C "$SCRIPTPATH" rev-parse --abbrev-ref HEAD) != "$BRANCH" ]] && echo -e "${YELLOW_BOLD}     You appear to be on a different branch so I will assume you are developing and do not want an update${CLEAR}" && echo && return
    timeout 1s git -C "$SCRIPTPATH" fetch --quiet
    timeout 1s git -C "$SCRIPTPATH" diff --quiet --exit-code "origin/$BRANCH" "$SCRIPTFILE"
    [ $? -eq 1 ] && {
      echo -e "${RED_REGULAR}   ✗ Version: Mismatched${CLEAR}"
      echo "✗ Version: Mismatched" >> "$LOG_FILE"
      echo
      echo -e "${YELLOW_BOLD}1a. Fetching Update...${CLEAR}"
      echo "1a. Fetching Update..." >> "$LOG_FILE"
      echo
      if [ -n "$(git -C "$SCRIPTPATH" status --porcelain)" ]; then
        git -C "$SCRIPTPATH" stash push -m 'local changes stashed before self update' --quiet
      fi
      git -C "$SCRIPTPATH" pull --force --quiet
      git -C "$SCRIPTPATH" checkout $BRANCH --quiet
      git -C "$SCRIPTPATH" pull --force --quiet
      echo -e "${GREEN_BOLD}   ✓ Update Complete. Running New Version. Standby...${CLEAR}"
      echo "✓ Update Complete. Running New Version. Standby..." >> "$LOG_FILE"
      sleep 3

      exec "$CALLEDSCRIPTNAME" "${ARGS[@]}"

      # Exit this old instance of the script
      exit 1
    }
    echo -e "${GREEN_BOLD}   ✓ Version: Current${CLEAR}"
  else
    echo -e "${RED_REGULAR}   ✗ Git Clone Not Detected: Skipping Update Check${CLEAR}"
  fi
  echo
}

# usage_example [<exit code>] - Show Usage and Exit (default 0). On a usage error the text goes to stderr.
usage_example() {
  local status="${1:-0}"
  [[ "$status" -ne 0 ]] && exec 1>&2 # we exit below, so redirecting the rest of the script is harmless
  echo 'Usage: ./kiwix-zim-updater.sh <options> /full/path/'
  echo ''
  echo '    /full/path/                Full path to ZIM directory'
  echo ''
  echo 'Universal Options:'
  echo '    -h, --help                 Show this usage and exit.'
  echo '    -u, --skip-update          Skips checking for script updates (very useful for development).'
  echo '    -g, --get-index            Forces using remote index rather than cached index. Cache auto clears after one day'
  echo '    -n <size>, --min-size      Minimum ZIM Size to be downloaded.'
  echo '                               Specify units include M Mi G Gi, etc. See `man numfmt`'
  echo '    -x <size>, --max-size      Maximum ZIM Size to be downloaded.'
  echo '                               Specify units include M Mi G Gi, etc. See `man numfmt`'
  echo '    -S, --no-sha               Disables saving the zim checksum for future reference. Does not delete present checksums.'
  echo '                               '
  echo 'Action Method Options:'
  echo '    -w, --web                  Downloads zims over http(s).'
  echo '    -t, --torrent              Downloads `.torrent` files. REQUIRES ADDITIONAL SOFTWARE TO EXECUTE DOWNLOAD.'
  echo '    '
  echo '    -f, --verify-library       Verifies that the entire library has the correct checksums as found online.'
  echo '                               Expected behavior is to create sha256 files during a normal run so this option can be used at a later date without internet.'
  echo '                               Disable this using -S'
  echo ''
  echo 'Web Download Options:'
  echo '    -c, --calculate-checksum   Verifies that the downloaded files were not corrupted, but can take a while for large downloads.'
  echo '    -p, --skip-purge           Skips purging any replaced ZIMs.'
  echo '    -l <location>, --location  Country Code to prefer mirrors from'
  echo '    -d, --disable-dry-run      Dry-Run Override.'
  echo '                               *** Caution ***'

  echo
  exit "$status"
}

# flags - Flag and ZIM Processing Functions
flags() {
  echo -e "${YELLOW_BOLD}2. Preprocessing...${CLEAR}"
  echo "2. Preprocessing..." >> "$LOG_FILE"
  echo
  echo -e "${BLUE_BOLD}  -Validating ZIM directory...${CLEAR}"
  echo "Validating ZIM directory..." >> "$LOG_FILE"

  # Let's identify which argument is the ZIM directory path and if it's an actual directory.
  if [[ -d ${1} ]]; then
    if [[ -w ${1} ]]; then
      ZIMPath=$1
    else
      ZIMPath=$1
      echo -e "${RED_REGULAR}  ✗ Cannot write to '${1}', continuing in dry-run${CLEAR}"
      echo "✗ Cannot write to '${1}', continuing in dry-run" >> "$LOG_FILE"
      echo
      DEBUG=1
    fi
  else # Um... no ZIM directory path provided? Okay, let's show the usage and exit.
    if [[ -z ${1} ]]; then
      echo -e "${RED_REGULAR}  ✗ Kiwix ZIM Directory not provided${CLEAR}"
      echo "✗ Kiwix ZIM Directory not provided" >> "$LOG_FILE"
    else
      echo -e "${RED_REGULAR}  ✗ '$1' is not a directory${CLEAR}"
      echo "✗ '$1' is not a directory" >> "$LOG_FILE"
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
    MyDate="$(echo "${LocalZIMArray[$index]}" | grep -oP "$YEAR_REGEX-$MONTH_REGEX(?=$END_ANCHOR_REGEX$)")"
    MyYear="$(echo "$MyDate" | grep -oP "$YEAR_REGEX(?=-$MONTH_REGEX)")"
    MyMonth="$(echo "$MyDate" | grep -oP "(?<=$YEAR_REGEX-)$MONTH_REGEX")"

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
          ScanDate="$(echo "${LocalZIMArray[$scanIndex]}" | grep -oP "$YEAR_REGEX-$MONTH_REGEX(?=$END_ANCHOR_REGEX$)")"
          ScanYear="$(echo "$ScanDate" | grep -oP "$YEAR_REGEX(?=-$MONTH_REGEX)")"
          ScanMonth="$(echo "$ScanDate" | grep -oP "(?<=$YEAR_REGEX-)$MONTH_REGEX")"

          # this file is not shadowed if it is newer.
          # this is caused by `ls -1` and `sort` having weird lexicons that make the prefix sort unreliable that 02a can sort between 01 and 02 instead of after 02
          if [[ $MyYear > $ScanYear ]]; then
            echo "Disregarding ${LocalZIMArray[$scanIndex]} because it is shadowed by ${LocalZIMArray[$index]}" >> "$LOG_FILE"
            duplicated=2
            break
          elif [[ $MyYear == $ScanYear ]] && [[ $MyMonth > $ScanMonth ]]; then
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
    exit 0
  else
    echo -e "${GREEN_BOLD}  ✓ Valid ZIM Directory ${CLEAR}"
  fi
  echo

  echo -e "${BLUE_BOLD}  -Building online ZIM list...${CLEAR}"

  # Build online ZIM list.
  master_scrape

  echo

  # Populate ZIM arrays from found ZIM(s)
  echo -e "${BLUE_BOLD}  -Parsing ZIM(s)...${CLEAR}"

  for ((i = 0; i < ${#LocalZIMArray[@]}; i++)); do                                             # Loop through local ZIM(s).
    LocalZIMNameArray[$i]=$(basename "${LocalZIMArray[$i]}")                                   # Extract file name.
    filename=$(basename "${LocalZIMArray[$i]}" | grep -ioP "^[\w:\/\-.]+(?=$COMPLETE_ENDING_REGEX$)") # Extract file name.
    #        IFS='_' read -ra fields <<< "${LocalZIMNameArray[$i]}"; unset IFS  # Break the filename into fields delimited by the underscore '_'

    # Search MasterZIMArray for the current local ZIM to discover the online Root (directory) for the URL
    for ((z = 0; z < ${#Basenames[@]}; z++)); do
      if [[ ${Basenames[$z]} == "$filename" ]]; then # Match Found (ignore the filename datepart).
        LocalZIMRemoteIndexArray[$i]="$z"
        break
      else # No Match Found.
        LocalZIMRemoteIndexArray[$i]="-1"
      fi
    done

    if [[ LocalZIMRemoteIndexArray[$i] -eq -1 ]]; then
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
  echo "$2 $1" >"$ZIMPath$1.sha256.tmp" && mv -f "$ZIMPath$1.sha256.tmp" "$ZIMPath$1.sha256"
}

# download_file - Download (or resume) $2 into $1, showing progress and logging it. Returns wget's own exit status,
# not tee's.
download_file() {
  wget -q --show-progress --progress=bar:force -c -O "$1" "$2" 2>&1 | tee -a "$LOG_FILE"
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
  MetaInfo=$(wget "${WGET_META_OPTS[@]}" -q -O - "$BaseURL$RemotePath.meta4?country=$COUNTRY_CODE")
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
      shift                               # discard -n argument
      MIN_SIZE=$(numfmt --from=auto "$1") # convert passed arg to bytes
      shift                               # discard value
      ;;
    -x | --max-size)
      shift                               # discard -x argument
      MAX_SIZE=$(numfmt --from=auto "$1") # convert passed arg to bytes
      shift                               # discard value
      ;;
    -l | --location)
      shift # discard -l argument
      if [[ "$1" =~ ^[A-Z]{2}$ ]]; then
        COUNTRY_CODE=$1 # convert passed arg to bytes
      else
        COUNTRY_CODE=""
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
    -u | --skip-update)
      SKIP_UPDATE=1
      shift
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
    -S | --no-sha)
      CHECKSUM_FILES=0
      shift
      ;;
    *)
      # We can either parse the arg here, or just tuck it away for safekeeping
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift                   # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters that we skipped earlier

clear # Clear screen

if [[ $CALCULATE_CHECKSUM -ne 0 ]] && [[ $DOWNLOAD_METHOD -ne 1 ]]; then
  echo -e "${RED_BOLD}Calculating Checksum not available with torrenting. Aborting.${CLEAR}"
fi

# Display Header
echo "=========================================="
echo " kiwix-zim-updater"
if [[ "$CALLEDSCRIPTFILE" == "kiwix-zim.sh" ]]; then
  echo " WARNING: kiwix-zim.sh has been deprecated "
  echo " in favor of kiwix-zim-updater             "
  echo "WARNING: kiwix-zim has been deprecated in favor of kiwix-zim-updater. kiwix-zim will be a hard link to the new script name until at least 2025-01-01" >> "$LOG_FILE"
fi
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

detect_wget_flavor

# First, Self-Update Check.
# Shouldnt this be first? it is not dependent on anything else and resets everything, so may as well reset it before getting all invested?
self_update

# Second, Flag Check.
flags "$@"

echo
echo -e "${YELLOW_BOLD}3. Processing ZIM(s)...${CLEAR}"
echo "3. Processing ZIM(s)..." >> "$LOG_FILE"
echo

AnyDownloads=0

for ((i = 0; i < ${#LocalZIMNameArray[@]}; i++)); do
  RemoteIndex=${LocalZIMRemoteIndexArray[$i]}
  FileName=${LocalZIMNameArray[$i]}
  if [[ $RemoteIndex -eq -1 ]]; then
    if [[ $VERIFY_LIBRARY -eq 1 ]] && [[ -f "$ZIMPath$FileName.sha256" ]]; then
      LocalRequiresDownloadArray+=(3)
      AnyDownloads=1
      echo -e "${BLUE_BOLD}  - $FileName:${CLEAR}"
      echo -e "${GREEN_REGULAR}    Cached Checksum Found${CLEAR}"
    else
      LocalRequiresDownloadArray+=(0)
    fi
    continue
  fi

  echo -e "${BLUE_BOLD}  - $FileName:${CLEAR}"
  [[ -f "$ZIMPath.~lock.$FileName" ]] && echo -e "${YELLOW_REGULAR}    Incomplete download detected\n${GREEN_BOLD}    ✓ Online Version Found${CLEAR}\n" && LocalRequiresDownloadArray+=(1) && AnyDownloads=1 && continue


  MatchingSize=${FileSizes[$RemoteIndex]}
  MatchingFileName=${RemoteFiles[$RemoteIndex]}
  MatchingFullPath=${RemotePaths[$RemoteIndex]}
  MatchingCategory=${RemoteCategory[$RemoteIndex]}

  [[ -f "$ZIMPath$MatchingFileName.torrent" ]] && [[ ! -f "$ZIMPath$MatchingFileName" ]] && echo -e "${YELLOW_REGULAR}    Torrent already downloaded\n${GREEN_BOLD}    ✓ Online Version Found${CLEAR}\n" && LocalRequiresDownloadArray+=(0) && continue

  MatchedDate="$(echo "$MatchingFileName" | grep -oP "$YEAR_REGEX-$MONTH_REGEX(?=$END_ANCHOR_REGEX$)")"
  MatchedYear="$(echo "$MatchedDate" | grep -oP "$YEAR_REGEX(?=-$MONTH_REGEX)")"
  MatchedMonth="$(echo "$MatchedDate" | grep -oP "(?<=$YEAR_REGEX-)$MONTH_REGEX")"

  LocalDate="$(echo "$FileName" | grep -oP "$YEAR_REGEX-$MONTH_REGEX(?=$END_ANCHOR_REGEX$)")"
  LocalYear="$(echo "$LocalDate" | grep -oP "$YEAR_REGEX(?=-$MONTH_REGEX)")"
  LocalMonth="$(echo "$LocalDate" | grep -oP "(?<=$YEAR_REGEX-)$MONTH_REGEX")"

  FileTooSmall=0
  [[ $MIN_SIZE -gt 0 ]] && [[ $MatchingSize -lt $MIN_SIZE ]] && FileTooSmall=1
  FileTooLarge=0
  [[ $MAX_SIZE -gt 0 ]] && [[ $MatchingSize -gt $MAX_SIZE ]] && FileTooLarge=1
  FileSizeAcceptable=0
  [ $FileTooSmall -eq 0 ] && [ $FileTooLarge -eq 0 ] && FileSizeAcceptable=1

  if [ $VERIFY_LIBRARY -eq 1 ] && [ $FileSizeAcceptable -eq 0 ]; then
    if [ $FileTooSmall -eq 1 ]; then
      LocalRequiresDownloadArray+=(0)
      [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Verification skipped due to file size (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
      [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Verification skipped due to file size (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
    elif [ $FileTooLarge -eq 1 ]; then
      LocalRequiresDownloadArray+=(0)
      [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Verification skipped due to file size (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
      [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Verification skipped due to file size (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize"))${CLEAR}"
    fi
  elif [[ "$MatchingFileName" == "$FileName" ]]; then
    if [ $VERIFY_LIBRARY -eq 1 ]; then
      LocalRequiresDownloadArray+=(1)
      AnyDownloads=1
      echo -e "${GREEN_BOLD}    ✓ Online Version Found${CLEAR}"
    else
      LocalRequiresDownloadArray+=(0)
      echo "    ✗ No new update"
    fi
  else
    if [ $VERIFY_LIBRARY -eq 1 ]; then
      if [[ -f "$ZIMPath$FileName.sha256" ]]; then
        LocalRequiresDownloadArray+=(2)
        AnyDownloads=1
        echo -e "${GREEN_REGULAR}    Cached Checksum Found${CLEAR}"
      else
        echo "    Checking for online checksum..."
        if wget -S --spider -q -O - "$BaseURL$MatchingCategory/$FileName.sha256" >/dev/null 2>&1; then
          LocalRequiresDownloadArray+=(4)
          AnyDownloads=1
          echo -e "${GREEN_BOLD}    ✓ Online Version Found${CLEAR}"
        else
          LocalRequiresDownloadArray+=(0)
          echo "    ✗ Online Version Not Found"
        fi
      fi
    else
      if [ $FileTooSmall -eq 1 ]; then
        LocalRequiresDownloadArray+=(0)
        [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Update skipped (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP "$YEAR_REGEX-$MONTH_REGEX(?=$END_ANCHOR_REGEX$)")${CLEAR}"
        [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Update skipped (minimum: $(numfmt --to=iec-i $MIN_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP "$YEAR_REGEX-$MONTH_REGEX(?=$END_ANCHOR_REGEX$)")${CLEAR}"
      elif [ $FileTooLarge -eq 1 ]; then
        LocalRequiresDownloadArray+=(0)
        [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Update skipped (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP "$YEAR_REGEX-$MONTH_REGEX(?=$END_ANCHOR_REGEX$)")${CLEAR}"
        [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ *** Simulated ***  Update skipped (maximum: $(numfmt --to=iec-i $MAX_SIZE), download size: $(numfmt --to=iec-i "$MatchingSize")). New version: $(echo "$MatchingFileName" | grep -oP "$YEAR_REGEX-$MONTH_REGEX(?=$END_ANCHOR_REGEX$)")${CLEAR}"
      elif [[ $MatchedYear < $LocalYear ]]; then
        LocalRequiresDownloadArray+=(0)
        echo "    ✗ No new update"
      elif [[ "$MatchedYear" == "$LocalYear" ]] && { [[ $MatchedMonth < $LocalMonth ]] || [[ "$MatchedMonth" == "$LocalMonth" ]] ; }; then
        LocalRequiresDownloadArray+=(0)
        echo "    ✗ No new update"
      else
        LocalRequiresDownloadArray+=(1)
        AnyDownloads=1
        echo -e "${GREEN_BOLD}    ✓ Update found! --> $MatchedDate${CLEAR}"
      fi
    fi
  fi
  echo
done

echo -e "${YELLOW_BOLD}4. Downloading New ZIM(s)...${CLEAR}"
echo -e "4. Downloading New ZIM(s)..." >> "$LOG_FILE"
echo

# Let's clear out any possible duplicates

# Let's Start the download process, but only if we have actual downloads to do.
if [ $AnyDownloads -eq 1 ]; then
  for ((z = 0; z < ${#LocalZIMNameArray[@]}; z++)); do # Iterate through the download queue.
    [[ ${LocalRequiresDownloadArray[$z]} -eq 0 ]] && continue

    # Per-file state: nothing may carry over from the previous ZIM (or leak in from the environment)
    DownloadFailed=0
    IsMirror=0
    DownloadURL=""
    ExpectedSize=""
    ExpectedHash=""

    OldZIM=${LocalZIMNameArray[$z]}
    OldZIMPath=$ZIMPath$OldZIM

    echo -e "${BLUE_BOLD}  Processing $OldZIM${CLEAR}"

    if [[ ${LocalRequiresDownloadArray[$z]} -eq 3 ]]; then
      ExpectedHash=$(grep -ioP "^[0-9a-f]{64}" <"$OldZIMPath.sha256")

      NewZIM="$OldZIM"
      NewZIMPath="$OldZIMPath"
    elif [[ ${LocalRequiresDownloadArray[$z]} -eq 4 ]]; then
      # Outdated ZIM: verify it against its own published checksum, not against the newer release's meta4
      ExpectedHash=$(wget -q -O - "$BaseURL${RemoteCategory[${LocalZIMRemoteIndexArray[$z]}]}/$OldZIM.sha256" 2>/dev/null | grep -ioP "^[0-9a-f]{64}")

      NewZIM="$OldZIM"
      NewZIMPath="$OldZIMPath"
    else
      mirror_search # Let's look for a mirror URL first.

      if [[ ${LocalRequiresDownloadArray[$z]} -eq 2 ]]; then
        ExpectedHash=$(grep -ioP "^[0-9a-f]{64}" <"$OldZIMPath.sha256")
      fi

      NewZIM=${RemoteFiles[${LocalZIMRemoteIndexArray[$z]}]}
      NewZIMPath=$ZIMPath$NewZIM
    fi


    FilePath=$ZIMPath$NewZIM              # Set destination path with file name
    LockFilePath="$ZIMPath.~lock.$NewZIM" # Set destination path with file name
    TorrentFilePath="$ZIMPath$NewZIM.torrent" # Set destination path with file name

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
        if [[ -f $LockFilePath ]]; then
          [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : ZIM download was interrupted. Continuing...${CLEAR}"
          [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  ZIM download was interrupted. Continuing...${CLEAR}"
        else
          [[ $DEBUG -eq 0 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : ZIM doesn't exist on disk. Downloading...${CLEAR}"
          [[ $DEBUG -eq 1 ]] && echo -e "${GREEN_REGULAR}    ✓ Status : *** Simulated ***  ZIM doesn't exist on disk. Downloading...${CLEAR}"
        fi
        echo
      fi
    else
      # lockfile implies an incomplete download
      if [[ -f $LockFilePath ]]; then
        echo "Incomplete download detected, resuming" >>"$LOG_FILE"
        echo -e "${YELLOW_REGULAR}    Status: Incomplete download detected, resuming${CLEAR}"

        #                [[ $IsMirror -eq 0 ]] && echo -e "${BLUE_BOLD}  Download (direct) : $DownloadURL${CLEAR}"
        #                [[ $IsMirror -eq 1 ]] && echo -e "${BLUE_BOLD}  Download (mirror) : $DownloadURL${CLEAR}"
        RequiresDownload=1
      elif [[ -f $TorrentFilePath ]]; then
        echo -e "${YELLOW_REGULAR}    Status: Torrent exists, skipping${CLEAR}"
        echo "Skipping checksum for torrent : $OldZIM. If the download has been completed, please delete the .torrent if you want me to verify the checksum." >>"$LOG_FILE"
      else
        # actually verify the file
        echo -e "${BLUE_REGULAR}    Calculating checksum for : $OldZIM${CLEAR}"
        echo "Calculating checksum for : $OldZIM" >>"$LOG_FILE"
        { [[ ${LocalRequiresDownloadArray[$z]} -eq 1 ]] || [[ ${LocalRequiresDownloadArray[$z]} -eq 4 ]]; } && write_checksum_file "$OldZIM" "$ExpectedHash"
        # An unknown expected size (failed meta4 fetch) is "cannot verify", never "corrupt"
        if [[ ${LocalRequiresDownloadArray[$z]} -eq 1 ]] && [[ "$ExpectedSize" =~ ^[0-9]+$ ]] && [[ $(du -b "$OldZIMPath" | grep -ioP "^\d+") -ne "$ExpectedSize" ]]; then
          RequiresDownload=1
          if [[ $DEBUG -eq 0 ]]; then
            if [[ $SKIP_PURGE -eq 0 ]]; then
              echo -e "${RED_BOLD}    ✗ Status : File size verification failed, removing corrupt file${CLEAR}"
              echo "✗ Status : File size verification failed, removing corrupt file" >>"$LOG_FILE"
              rm "$OldZIMPath"
            else
              echo -e "${RED_BOLD}    ✗ Status : File size verification failed but purge skipped${CLEAR}"
              echo "✗ Status : File size verification failed but purge skipped" >>"$LOG_FILE"
            fi
          else
            [[ $SKIP_PURGE -eq 0 ]] && echo -e "${RED_BOLD}    ✗ Status : *** Simulated *** File size verification failed, removing corrupt file ($FilePath)${CLEAR}"
            [[ $SKIP_PURGE -eq 1 ]] && echo -e "${RED_BOLD}    ✗ Status : *** Simulated *** File size verification failed but purge skipped ($FilePath)${CLEAR}"
          fi

          echo
        elif [[ ${#ExpectedHash} -ne 64 ]]; then
          echo -e "${YELLOW_BOLD}    No valid checksum available (metadata unavailable?), cannot verify $OldZIM. Skipping, file kept.${CLEAR}" && echo "Cannot verify $OldZIM: no valid checksum available, file kept" >>"$LOG_FILE"
        elif ! hash_matches "$OldZIM" "$ExpectedHash"; then
          # we checked a very old file, but we will choose to not replace it because we cannot, so we will leave it. A regular update will purge it naturally
          if [[ ${LocalRequiresDownloadArray[$z]} -eq 3 ]]; then
            echo -e "${RED_BOLD}    ✗ Checksum failed, but no online version to replace it with. File kept.${CLEAR}"
            echo "✗ Checksum failed for $OldZIM, no online version to replace it with. File kept." >>"$LOG_FILE"
            echo
            continue
          elif [[ ${LocalRequiresDownloadArray[$z]} -ne 1 ]]; then
            echo -e "${RED_BOLD}    ✗ Checksum failed. File kept; a normal update run (without -f) will replace it with the newer version.${CLEAR}"
            echo "✗ Checksum failed for $OldZIM. File kept; a normal update run will replace it with the newer version." >>"$LOG_FILE"
            echo
            continue
          fi
          if [[ $DEBUG -eq 0 ]]; then
            if [[ $SKIP_PURGE -eq 0 ]]; then
              echo -e "${RED_BOLD}    ✗ Status : Checksum failed, removing corrupt file${CLEAR}"
              echo "✗ Status : Checksum failed, removing corrupt file" >>"$LOG_FILE"
              rm "$OldZIMPath"
              rm "$OldZIMPath.sha256" 2>/dev/null
            else
              echo -e "${RED_BOLD}    ✗ Status : Checksum failed but purge was skipped${CLEAR}"
              echo "✗ Status : Checksum failed but purge was skipped" >>"$LOG_FILE"
              echo
              continue
            fi
          else
            echo -e "${RED_BOLD}    ✗ Status : *** Simulated *** Checksum failed, removing corrupt file ($FilePath)${CLEAR}"
          fi

          RequiresDownload=1
          echo
        else
          echo -e "${GREEN_BOLD}    ✓ Status : Checksum passed${CLEAR}"
          echo "✓ Status : Checksum passed" >>"$LOG_FILE"

          [[ $DEBUG -eq 0 ]] && echo "End : $(date -u)" >>"$LOG_FILE"
          [[ $DEBUG -eq 1 ]] && echo "End : $(date -u) *** Simulation ***" >>"$LOG_FILE"

          #                    rm "$OldZIMPath.sha256"

          echo
          continue
        fi
        # Verified against its own checksum only (states 2, 3 and 4): there is nothing to download
        [[ ${LocalRequiresDownloadArray[$z]} -ne 1 ]] && continue
        #                rm "$OldZIMPath.sha256"
      fi
    fi
    echo >>"$LOG_FILE"
    [[ $DEBUG -eq 0 ]] && echo "Start : $(date -u)" >>"$LOG_FILE"
    [[ $DEBUG -eq 1 ]] && echo "Start : $(date -u) *** Simulation ***" >>"$LOG_FILE"
    # Here is where we actually download the files and log to the download.log file.
    if [[ $RequiresDownload -eq 1 ]]; then
      [[ $IsMirror -eq 0 ]] && echo -e "${BLUE_REGULAR}    Download (direct) : $DownloadURL${CLEAR}"
      [[ $IsMirror -eq 1 ]] && echo -e "${BLUE_REGULAR}    Download (mirror) : $DownloadURL${CLEAR}"

      echo >>"$LOG_FILE"
      echo "=======================================================================" >>"$LOG_FILE"
      echo "File : $NewZIM" >>"$LOG_FILE"
      [[ $IsMirror -eq 0 ]] && echo "URL (direct) : $DownloadURL" >>"$LOG_FILE"
      [[ $IsMirror -eq 1 ]] && echo "URL (mirror) : $DownloadURL" >>"$LOG_FILE"
      echo >>"$LOG_FILE"

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
          # wget leaves a partial or empty .torrent behind, which would be mistaken for a finished one next run
          rm -f "$FilePath"
          echo -e "${RED_BOLD}    ✗ Status : Torrent download failed${CLEAR}"
          echo "✗ Status : Torrent download failed" >>"$LOG_FILE"
          echo " !!! DOWNLOAD FAILED !!!" >>"$LOG_FILE"
          echo
        fi
        continue
      else
        # Before we actually download, let's just check to see that it isn't already in the folder.
        if [[ -f "$LockFilePath" ]]; then
          [[ $DEBUG -eq 0 ]] && { download_file "$FilePath" "$DownloadURL" || DownloadFailed=1; } # Download new ZIM
          [[ $DEBUG -eq 1 ]] && echo "Continue Download : $FilePath" >>"$LOG_FILE"
        elif [[ -f $FilePath ]]; then # New ZIM already found, we don't need to download it.
          [[ $DEBUG -eq 1 ]] && echo "Download : New ZIM already exists on disk. Skipping download." >>"$LOG_FILE"
        else # New ZIM not found, so we'll go ahead and download it.
          [[ $DEBUG -eq 0 ]] && touch "$LockFilePath"
          [[ $DEBUG -eq 0 ]] && { download_file "$FilePath" "$DownloadURL" || DownloadFailed=1; } # Download new ZIM
          [[ $DEBUG -eq 1 ]] && echo "Download : $FilePath" >>"$LOG_FILE"
        fi
      fi
    fi

    [[ $DEBUG -eq 0 ]] && [[ $DownloadFailed -eq 1 ]] && echo -e "${RED_BOLD}    ✗ Status : Download failed${CLEAR}" && echo "✗ Status : Download failed" >>"$LOG_FILE"

    # Never purge on an unverified file: whatever we downloaded, or are about to replace the old ZIM with, must match
    # the size published in the meta4. The catalog length is rounded to whole KiB, so it is no substitute.
    if [[ $DEBUG -eq 0 ]] && [[ $DownloadFailed -ne 1 ]] && { [[ $RequiresDownload -eq 1 ]] || [[ $VERIFY_LIBRARY -eq 0 ]]; }; then
      ActualSize=$(stat -c %s "$NewZIMPath" 2>/dev/null)
      if ! [[ "$ExpectedSize" =~ ^[0-9]+$ ]]; then
        echo -e "${RED_BOLD}    ✗ Status : Expected size unknown (metadata unavailable), cannot verify $NewZIM${CLEAR}"
        echo "✗ Status : Expected size unknown (metadata unavailable), cannot verify $NewZIM" >>"$LOG_FILE"
        DownloadFailed=1
      elif [[ "$ActualSize" != "$ExpectedSize" ]]; then
        echo -e "${RED_BOLD}    ✗ Status : File size verification failed (expected $ExpectedSize, found ${ActualSize:-no file})${CLEAR}"
        echo "✗ Status : File size verification failed (expected $ExpectedSize, found ${ActualSize:-no file})" >>"$LOG_FILE"
        DownloadFailed=1
      fi
    fi

    [[ $DownloadFailed -ne 1 ]] && write_checksum_file "$NewZIM" "$ExpectedHash"
    # In -f mode a file that was not (re-)downloaded has already been verified above
    if [[ $CALCULATE_CHECKSUM -eq 1 ]] && [[ $DownloadFailed -ne 1 ]] && { [[ $RequiresDownload -eq 1 ]] || [[ $VERIFY_LIBRARY -eq 0 ]]; }; then
      echo -e "${BLUE_REGULAR}    Calculating checksum for : $NewZIMPath${CLEAR}"
      if [[ $(du -b "$NewZIMPath" 2>/dev/null | grep -ioP "^\d+") -ne "$ExpectedSize" ]]; then
        if [[ $DEBUG -eq 0 ]]; then
          echo -e "${RED_BOLD}    ✗ Status : File size verification failed, removing corrupt file${CLEAR}"
          echo "✗ Status : File size verification failed, removing corrupt file" >>"$LOG_FILE"
          rm "$NewZIMPath"
        else
          echo -e "${GREEN_BOLD}    ✓ *** Simulated *** Checksum passed${CLEAR}"
        fi
      elif [[ ${#ExpectedHash} -ne 64 ]]; then
        echo -e "${YELLOW_BOLD}    This hash doesn't look quite right...skipping${CLEAR}"
      elif [[ $DEBUG -eq 0 ]] && ! hash_matches "$NewZIM" "$ExpectedHash"; then
        echo -e "${RED_BOLD}    ✗ Checksum failed, removing corrupt file${CLEAR}"
        rm "$NewZIMPath"
        DownloadFailed=1
      else
        if [[ $DEBUG -eq 0 ]]; then
          echo -e "${GREEN_BOLD}    ✓ Checksum passed${CLEAR}"
        else
          echo -e "${GREEN_BOLD}    ✓ *** Simulated *** Checksum passed${CLEAR}"
        fi
      fi
      #            rm "$NewZIMPath.sha256"
      #            rm "$LockFilePath"
      echo
    fi

    echo >> "$LOG_FILE"
    [[ $DownloadFailed -eq 1 ]] && echo " !!! DOWNLOAD FAILED !!!" >>"$LOG_FILE"

    # in all of these cases, we will not re-purge and will leave the lockfile so we know to resume later
    if [[ $DownloadFailed -eq 1 ]] || [[ $SKIP_PURGE -eq 1 ]] || [[ $VERIFY_LIBRARY -eq 1 ]]; then
      [[ $DEBUG -eq 0 ]] && echo "End : $(date -u)" >>"$LOG_FILE"
      [[ $DEBUG -eq 1 ]] && echo "End : $(date -u) *** Simulation ***" >>"$LOG_FILE"
      [[ $DEBUG -eq 0 ]] && [[ $SKIP_PURGE -eq 1 ]] && [[ $DownloadFailed -ne 1 ]] && rm "$LockFilePath"
      [[ $DEBUG -eq 0 ]] && [[ $VERIFY_LIBRARY -eq 1 ]] && [[ $RequiresDownload -eq 1 ]] && [[ $DownloadFailed -ne 1 ]] && rm "$LockFilePath"
      continue
    fi

    [[ $RequiresDownload -eq 1 ]] && [[ $DEBUG -eq 0 ]] && rm "$LockFilePath"

    ########################################

    echo -e "${BLUE_REGULAR}    Old : $OldZIM${CLEAR}"
    echo "Old : $OldZIM" >>"$LOG_FILE"
    echo -e "${BLUE_BOLD}    New : $NewZIM${CLEAR}"
    echo "New : $NewZIM" >>"$LOG_FILE"
    # Check for the new ZIM on disk.
    if [[ -f "$NewZIMPath" ]]; then # New ZIM found
      if [[ $DEBUG -eq 0 ]]; then
        if [[ "$OldZIMPath" == "$NewZIMPath" ]]; then
          echo -e "${GREEN_BOLD}    ✓ Status : New ZIM downloaded successfully.${CLEAR}"
          echo "✓ Status : New ZIM downloaded successfully." >>"$LOG_FILE"
          #                    rm "$OldZIMPath.sha256" 2>/dev/null # Purge old ZIM
        else
          echo -e "${GREEN_BOLD}    ✓ Status : New ZIM downloaded successfully. Old ZIM purged.${CLEAR}"
          echo "✓ Status : New ZIM downloaded successfully. Old ZIM purged." >>"$LOG_FILE"
          [[ -f "$OldZIMPath" ]] && rm "$OldZIMPath" && rm "$OldZIMPath.sha256" 2>/dev/null # Purge old ZIM
        fi
      else
        echo -e "${GREEN_BOLD}    ✓ Status : *** Simulated ***${CLEAR}"
        echo "✓ Status : *** Simulated ***" >>"$LOG_FILE"
      fi
    else # New ZIM not found. Something went wrong, so we will skip this purge.
      if [[ $DEBUG -eq 0 ]]; then
        echo -e "${RED_BOLD}    ✗ Status : New ZIM failed verification. Old ZIM not purged.${CLEAR}"
        echo "✗ Status : New ZIM failed verification. Old ZIM not purged." >>"$LOG_FILE"
      else
        if [[ $RequiresDownload -eq 1 ]]; then
          echo -e "${GREEN_BOLD}    ✓ Status : *** Simulated *** New zim exists, old zim purged${CLEAR}"
          echo "✓ Status : *** Simulated *** New zim exists, old zim purged" >>"$LOG_FILE"
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

  if [[ $DEBUG -eq 0 ]]; then
    IFS=$'\n' HangingFileLocks=("$ZIMPath".~lock.*.zim)
    unset IFS

    if [[ ${#HangingFileLocks[@]} -gt 0 ]]; then
      echo -e "${YELLOW_BOLD}5. Cleaning up...${CLEAR}"
      echo "5. Cleaning up..." >> "$LOG_FILE"
      echo

      for ((i = 0; i < ${#HangingFileLocks[@]}; i++)); do
        baseFileName=$(echo "${HangingFileLocks[$i]}" | grep -ioP "(?<=\.~lock\.).*$")
        echo -e "  ${RED_BOLD}Found broken lock: ${HangingFileLocks[$i]}${CLEAR}"
        echo "Found broken lock: ${HangingFileLocks[$i]}" >> "$LOG_FILE"
        if [[ -f "$ZIMPath$baseFileName" ]]; then
          echo -e "  ${BLUE_BOLD}Found abandoned download: $ZIMPath$baseFileName${CLEAR}"
          echo -e "Found abandoned download: $ZIMPath$baseFileName" >> "$LOG_FILE"
          rm "$ZIMPath$baseFileName"
        fi
        if [[ -f "$ZIMPath$baseFileName.sha256" ]]; then
          echo -e "  ${BLUE_BOLD}Found abandoned checksum: $ZIMPath$baseFileName.sha256${CLEAR}"
          echo -e "Found abandoned checksum: $ZIMPath$baseFileName.sha256" >> "$LOG_FILE"
          rm "$ZIMPath$baseFileName.sha256"
        fi
        rm  "${HangingFileLocks[$i]}"
        echo
      done
    fi
  fi
else
  echo -e "${GREEN_REGULAR}    ✓ Download: Nothing to download.${CLEAR}"
  echo "✓ Download: Nothing to download." >> "$LOG_FILE"
  echo
fi

if [[ "$CALLEDSCRIPTFILE" == "kiwix-zim.sh" ]]; then
  echo "WARNING: kiwix-zim has been deprecated in favor of kiwix-zim-updater. kiwix-zim will be a hard link to the new script name until at least 2025-01-01.\n This exit code is nonzero, but the script has not errored out. This is simply so you may notice and switch to using kiwix-zim-updater " >> "$LOG_FILE"
  exit 2
fi