#!/bin/zsh
set -eu
cd "${0:A:h}/.."
swift build -c release
app="dist/Meetly.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/MeetingAssist "$app/Contents/MacOS/MeetingAssist"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.akshay.meetingassist</string>
<key>CFBundleName</key><string>Meetly</string>
<key>CFBundleDisplayName</key><string>Meetly</string>
<key>CFBundleIconFile</key><string>MeetlyLeafIcon.icns</string>
<key>CFBundleExecutable</key><string>MeetingAssist</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.9.1</string>
<key>CFBundleVersion</key><string>30</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Capture meeting audio, optionally analyze main-display screenshots for coding help, and create a local sharing window that excludes Meetly.</string>
<key>NSMicrophoneUsageDescription</key><string>Optionally follow your speaking position locally or include spoken responses as meeting context.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Follow your speaking position using on-device transcription when you select Follow my speech.</string>
</dict></plist>
PLIST
mkdir -p "$app/Contents/Resources/Editor Companions"
swiftc Sources/MeetingAssist/BrandMark.swift scripts/brand-icon/main.swift -o dist/generate-brand-icon
dist/generate-brand-icon Assets/MeetlyIcon.png
swift scripts/build-icon.swift dist/Meetly.iconset
swift scripts/check-icon.swift dist/Meetly.iconset
iconutil -c icns dist/Meetly.iconset -o "$app/Contents/Resources/MeetlyLeafIcon.icns"
cp Assets/MeetlyIcon.png "$app/Contents/Resources/MeetlyArtwork.png"
python3 scripts/build-editor-companions.py
ditto 'dist/Editor Companions' "$app/Contents/Resources/Editor Companions"
python3 - "$app" <<'PY'
import pathlib, plistlib, sys
bundle = pathlib.Path(sys.argv[1])
with (bundle / 'Contents/Info.plist').open('rb') as source:
    info = plistlib.load(source)
assert info.get('LSUIElement') is True, 'The app must launch without a Dock icon.'
assert info.get('CFBundleIdentifier') == 'com.akshay.meetingassist', 'Stable app identity is required.'
assert (bundle / 'Contents/MacOS' / info['CFBundleExecutable']).is_file(), 'App executable missing.'
assert (bundle / 'Contents/Resources' / info['CFBundleIconFile']).stat().st_size > 0, 'App icon missing.'
assert (bundle / 'Contents/Resources/MeetlyArtwork.png').read_bytes() == pathlib.Path('Assets/MeetlyIcon.png').read_bytes(), 'App artwork must match the current source.'
print('Agent app bundle and icon checks passed.')
PY
identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    development_identities=(${(@f)$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')})
    if (( ${#development_identities} == 1 )); then
        identity="$development_identities[1]"
    else
        identity='-'
        print 'Using a temporary local signature. Set CODESIGN_IDENTITY to preserve recording permissions across rebuilds.'
    fi
fi
codesign --force --sign "$identity" --identifier com.akshay.meetingassist "$app"
codesign --verify --deep --strict "$app"
print "Built: ${PWD}/$app"
