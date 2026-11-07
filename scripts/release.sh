#!/bin/zsh
# Builds, signs for Sparkle and publishes a GitHub release:
#   scripts/release.sh            (run on an up-to-date, clean main)
# Uploads LocalAIBar-<version>.zip and appcast.xml; the app checks
# releases/latest/download/appcast.xml for updates. Notes come from docs/releases/v<version>.md.
# The EdDSA private key comes from $SPARKLE_PRIVATE_KEY, else from the login keychain (account "LocalAIBar",
# made with Sparkle's generate_keys). Its public half is SUPublicEDKey in Resources/Info.plist.
set -euo pipefail

root=${0:A:h:h}
cd "$root"
repo=DeMoZ/local-ai-bar
url=https://github.com/$repo

plist=Resources/Info.plist
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $plist)
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $plist)
minimum=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" $plist)
notes_md=docs/releases/v$version.md

[[ $(git branch --show-current) == main ]] || { echo "Release from main only"; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Working tree is not clean"; exit 1; }
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main is not in sync with origin/main"; exit 1; }
[[ -f $notes_md ]] || { echo "Missing $notes_md"; exit 1; }
gh release view "v$version" -R $repo >/dev/null 2>&1 && { echo "Release v$version already exists"; exit 1; }

./scripts/build-app.sh
zip=build/LocalAIBar-$version.zip
rm -f "$zip"
ditto -c -k --keepParent build/LocalAIBar.app "$zip"

sign_update=$(find .build/artifacts -path "*/Sparkle/bin/sign_update" -type f | head -1)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$zip")
else
  signature=$("$sign_update" --account LocalAIBar "$zip")
fi
[[ "$signature" == *edSignature=* ]] || { echo "Signing failed: $signature"; exit 1; }

# Release notes as simple HTML for Sparkle's update window.
notes_html=$(python3 -I - "$notes_md" <<'EOF'
import html, re, sys
text = open(sys.argv[1], encoding="utf-8").read().split("## Install")[0].strip()
def inline(s):
    s = html.escape(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", s)
out = []
for block in re.split(r"\n\s*\n", text):
    lines = [l.strip() for l in block.splitlines() if l.strip()]
    if not lines: continue
    if lines[0].startswith("## "): out.append(f"<h3>{inline(lines[0][3:])}</h3>")
    elif lines[0].startswith("- "): out.append("<ul>" + "".join(f"<li>{inline(l[2:])}</li>" for l in lines if l.startswith("- ")) + "</ul>")
    else: out.append(f"<p>{inline(' '.join(lines))}</p>")
print("\n".join(out))
EOF
)

cat > build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LocalAIBar</title>
    <link>$url</link>
    <item>
      <title>Version $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$url/releases</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
$notes_html
      ]]></description>
      <enclosure url="$url/releases/download/v$version/${zip:t}" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
EOF

gh release create "v$version" "$zip" build/appcast.xml -R $repo --target main \
  --title "LocalAIBar $version" --notes-file "$notes_md"
echo "Released v$version"
