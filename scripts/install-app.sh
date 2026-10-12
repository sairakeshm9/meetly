#!/bin/zsh
set -eu
cd "${0:A:h}/.."
./scripts/build-app.sh
target_app="$HOME/Applications/Meetly.app"
if [[ -e "$target_app" ]]; then
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target_app/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$existing_id" != 'com.akshay.meetingassist' ]]; then
        print -u2 'Another app exists at the install path; refusing to replace it.'
        exit 1
    fi
fi
mkdir -p "$HOME/Applications"
legacy_app="$HOME/Applications/Meeting Assist.app"
if [[ ! -e "$target_app" && -e "$legacy_app" ]]; then
    legacy_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$legacy_app/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$legacy_id" == 'com.akshay.meetingassist' ]]; then
        mv "$legacy_app" "$target_app"
    fi
fi
ditto 'dist/Meetly.app' "$target_app"
touch "$target_app"
codesign --verify --deep --strict "$target_app"
# Replacing a stable bundle also requires refreshing its Launch Services metadata.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target_app"
print "Installed: $target_app"
