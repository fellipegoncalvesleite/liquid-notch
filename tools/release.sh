#!/bin/zsh
# Builds a public release and its update feed, ready to attach to a GitHub release. Publishes nothing.
#   tools/release.sh
# Makes dist/release/<version>/Liquid-Notch-<version>.zip (ad-hoc signed, universal) and appcast.xml, whose notes are
# CHANGELOG.md's "## <version>" section. Installed copies read the appcast from the latest release
# (SUFeedURL: releases/latest/download/appcast.xml), so every release must carry both files:
#   gh release create v<version> dist/release/<version>/Liquid-Notch-<version>.zip dist/release/<version>/appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $PLIST)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" $PLIST)
MINIMUM=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" $PLIST)
FEED_KEY=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" $PLIST)
REPO=https://github.com/fellipegoncalvesleite/liquid-notch

# Only committed code ships: anything uncommitted in what goes into the app stops the release.
DIRTY=$(git status --porcelain -- Sources Resources Vendor Package.swift Package.resolved build_app.sh CHANGELOG.md)
[[ -z "$DIRTY" ]] || { print -u2 "Uncommitted changes would ship:\n$DIRTY"; exit 1; }

# The key that signs must be the one the app trusts, or no installed copy will take the update.
[[ "$(tools/updates.sh pubkey)" == "$FEED_KEY" ]] || { print -u2 "The signing key doesn't match SUPublicEDKey in $PLIST"; exit 1; }

# The notes: the changelog's section for this version, as HTML.
NOTES=$(awk -v v="## $VERSION" '$0 == v {on=1; next} /^## / {on=0} on' CHANGELOG.md | sed '/^[[:space:]]*$/d')
[[ -n "$NOTES" ]] || { print -u2 "CHANGELOG.md has no \"## $VERSION\" section"; exit 1; }
HTML=$(print -r -- "$NOTES" | sed -E 's/^- (.*)$/<li>\1<\/li>/; s/\*\*([^*]+)\*\*/<b>\1<\/b>/g')

[[ -d .build/adapter/MediaRemoteAdapter.framework ]] || tools/build_adapter.sh
LN_ADHOC=1 ./build_app.sh

OUT=dist/release/$VERSION
ZIP=$OUT/Liquid-Notch-$VERSION.zip
rm -rf $OUT
mkdir -p $OUT
ditto -c -k --sequesterRsrc --keepParent "dist/Liquid Notch.app" $ZIP
SIG=$(tools/updates.sh sign $ZIP)
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > $OUT/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Liquid Notch</title>
    <link>$REPO</link>
    <description>Liquid Notch updates</description>
    <language>en</language>
    <item>
      <title>Liquid Notch $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <description><![CDATA[<ul>
$HTML
</ul>]]></description>
      <enclosure url="$REPO/releases/download/v$VERSION/Liquid-Notch-$VERSION.zip" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
XML
xmllint --noout $OUT/appcast.xml
print "Built $ZIP and $OUT/appcast.xml (Liquid Notch $VERSION, build $BUILD). To publish:"
print "  gh release create v$VERSION $ZIP $OUT/appcast.xml --title \"Liquid Notch $VERSION\" --notes-file <(awk -v v=\"## $VERSION\" '\$0 == v {on=1; next} /^## / {on=0} on' CHANGELOG.md)"
