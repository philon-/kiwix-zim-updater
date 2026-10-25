#!/usr/bin/env bash
# Regenerate the test fixtures served by test/helpers/bin/wget.
#
# Output (committed to the repository):
#   catalog.xml                      trimmed OPDS feed in the real line format
#   remote/zim/<cat>/<file>          payload ("ZIM") with deterministic content
#   remote/zim/<cat>/<file>.meta4    metalink: size, hashes, priority-1 mirror
#   remote/zim/<cat>/<file>.sha256   "<hash>  <file>", as served by kiwix
#   remote/zim/<cat>/<file>.torrent  fake bencoded torrent
#
# The output is deterministic: running this twice yields identical files.
# The feed's own <updated> is the placeholder __NOW__; the wget stub replaces
# it at serve time so a cached kiwix-index is always "fresh" within a test.
#
# The real catalog's length="" attribute is the file size rounded up to whole
# KiB, while the .meta4 <size> is exact. The wiktionary payload is deliberately
# not a KiB multiple, so any code that trusts the catalog length as the exact
# size fails the download tests.

set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host="https://download.kiwix.test"
mirror="https://mirror.kiwix.test"

# category  file-name-without-.zim  size-in-bytes  entry-date
entries=(
  "wikipedia  wikipedia_en_test_2026-01    4096   2026-01-15"
  "wiktionary wiktionary_fr_test_2026-02a  3000   2026-02-20"
  "other      small_test_2025-12           1024   2025-12-01"
  "other      big_test_2026-03             16384  2026-03-10"
)

rm -rf "$here/remote"
mkdir -p "$here/remote/zim"

catalog="$here/catalog.xml"
{
  cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:dc="http://purl.org/dc/terms/"
      xmlns:opds="https://specs.opds.io/opds-1.2"
      xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">
  <id>00000000-0000-4000-8000-000000000000</id>

  <link rel="self"
        href="/catalog/v2/entries?count=-1"
        type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
  <link rel="start"
        href="/catalog/v2/root.xml"
        type="application/atom+xml;profile=opds-catalog;kind=navigation"/>

  <title>Filtered Entries (count=-1)</title>
  <updated>__NOW__</updated>
EOF
  printf '  <totalResults>%d</totalResults>\n' "${#entries[@]}"
  printf '  <startIndex>0</startIndex>\n'
  printf '  <itemsPerPage>%d</itemsPerPage>\n' "${#entries[@]}"
} >"$catalog"

n=0
for entry in "${entries[@]}"; do
  read -r cat name size date <<<"$entry"
  n=$((n + 1))
  file="$name.zim"
  dir="$here/remote/zim/$cat"
  mkdir -p "$dir"

  head -c "$size" < <(yes "kiwix-zim-updater test fixture payload: $file") >"$dir/$file"

  sha256=$(sha256sum "$dir/$file" | cut -d' ' -f1)
  sha1=$(sha1sum "$dir/$file" | cut -d' ' -f1)
  md5=$(md5sum "$dir/$file" | cut -d' ' -f1)

  printf '%s  %s\n' "$sha256" "$file" >"$dir/$file.sha256"

  tracker="https://tracker.kiwix.test/announce"
  printf 'd8:announce%d:%s4:infod6:lengthi%de4:name%d:%see' \
    "${#tracker}" "$tracker" "$size" "${#file}" "$file" >"$dir/$file.torrent"

  cat >"$dir/$file.meta4" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<metalink xmlns="urn:ietf:params:xml:ns:metalink">
  <generator>MirrorBrain/2.19.0</generator>
  <origin dynamic="true">$host/zim/$cat/$file.meta4</origin>
  <published>${date}T00:00:00Z</published>
  <publisher>
    <name>Kiwix project</name>
    <url>https://kiwix.org</url>
  </publisher>

  <file name="$file">
    <size>$size</size>

    <!-- internal id: $n -->
    <hash type="md5">$md5</hash>
    <hash type="sha-1">$sha1</hash>
    <hash type="sha-256">$sha256</hash>
    <pieces length="4194304" type="sha-1">
      <hash>$sha1</hash>
    </pieces>

    <!-- Mirrors which handle this country (TEST): -->
    <url location="se" priority="1">$mirror/zim/$cat/$file</url>

    <!-- Mirrors in the rest of the world: -->
    <url location="fr" priority="2">$host/zim/$cat/$file</url>
  </file>
</metalink>
EOF

  length=$(( (size + 1023) / 1024 * 1024 ))
  cat >>"$catalog" <<EOF
  <entry>
    <id>urn:uuid:00000000-0000-4000-8000-00000000000$n</id>
    <title>Test entry $name</title>
    <updated>${date}T00:00:00Z</updated>
    <summary>Fixture for kiwix-zim-updater tests</summary>
    <language>eng</language>
    <name>${name%_*}</name>
    <flavour></flavour>
    <category>$cat</category>
    <tags>_category:$cat;_ftindex:no;_pictures:no;_videos:no;_details:yes</tags>
    <articleCount>1</articleCount>
    <mediaCount>0</mediaCount>
    <link rel="http://opds-spec.org/image/thumbnail"
          href="/catalog/v2/illustration/00000000-0000-4000-8000-00000000000$n/?size=48"
          type="image/png;width=48;height=48;scale=1"/>
    <link type="text/html" href="https://browse.library.kiwix.test/content/$name" />
    <author>
      <name>Test</name>
    </author>
    <publisher>
      <name>openZIM</name>
    </publisher>
    <dc:issued>${date}T00:00:00Z</dc:issued>
    <link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" href="$host/zim/$cat/$file.meta4" length="$length" />
  </entry>
EOF
done

echo "</feed>" >>"$catalog"
