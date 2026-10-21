#!/bin/zsh
# Archives the iOS and Mac apps, uploads both to App Store Connect, and sets
# each build's "What to Test" from changelogs/<version>-<build>.md.
#
# Needs the API key in keys/ (git-ignored): appstoreconnect.p8, and its ids in
# appstoreconnect.keyid and appstoreconnect.issuer.
set -euo pipefail
cd "$(dirname "$0")/.."

setting() { sed -n "s/^$1 *= *//p" Config/Base.xcconfig | tr -d '[:space:]'; }
version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
bundle=$(setting BUNDLE_ID_PREFIX)
notes=changelogs/$version-$build.md
key=$PWD/keys/appstoreconnect.p8
key_id=$(tr -d '[:space:]' < keys/appstoreconnect.keyid)
issuer=$(tr -d '[:space:]' < keys/appstoreconnect.issuer)

[[ -f $notes ]] || { echo "No $notes: write the changelog first." >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Uncommitted changes: upload from a clean tree." >&2; exit 1; }

archives=${YAPNEST_ARCHIVES:-$HOME/Library/Caches/yapnest-archives}/$version-$build
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")
options=$(mktemp -t export).plist
trap 'rm -f "$options"' EXIT
cat > "$options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF

xcodegen generate
# One after the other: two archives at once lock each other's build database.
for platform in ios mac; do
  destination=$([[ $platform == ios ]] && echo 'generic/platform=iOS' || echo 'generic/platform=macOS,variant=Mac Catalyst')
  echo "== $platform $version ($build)"
  xcodebuild archive -scheme Yapnest -configuration Release -destination "$destination" \
    -archivePath "$archives/$platform.xcarchive" "${auth[@]}" -quiet
  xcodebuild -exportArchive -archivePath "$archives/$platform.xcarchive" -exportOptionsPlist "$options" \
    -exportPath "$archives/$platform-export" "${auth[@]}"
done

for platform in IOS MAC_OS; do
  swift dev/testflight-notes.swift "$key" "$key_id" "$issuer" "$bundle" "$version" "$build" "$platform" "$notes"
done
