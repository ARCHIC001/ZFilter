#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/ZFilter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos26.0 -parse-as-library GUI/Filter.swift GUI/Operations.swift GUI/ImageViewer.swift GUI/MediaDecoder.swift GUI/Histogram.swift GUI/FocusMetadata.swift GUI/NikonLensDistance.swift GUI/BurstMetadata.swift GUI/Filmstrip.swift GUI/Appearance.swift GUI/SelfTest.swift -o "$APP/Contents/MacOS/ZFilter"
cp nikonfilter.py GUI/filter_bridge.py "$APP/Contents/Resources/"
xcrun swift GUI/DrawIcon.swift "$PWD/build"
cp build/AppIcon.png build/AppIcon.pdf "$APP/Contents/Resources/"
iconutil -c icns build/ZFilter.iconset -o "$APP/Contents/Resources/ZFilter.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ZFilter</string>
<key>CFBundleIdentifier</key><string>studio.archicyan.filter</string>
<key>CFBundleName</key><string>ZFilter</string>
<key>CFBundleDisplayName</key><string>ZFilter</string>
<key>CFBundleVersion</key><string>21</string>
<key>CFBundleShortVersionString</key><string>1.9.7</string>
<key>CFBundleIconFile</key><string>ZFilter.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  installed="$HOME/Applications/ZFilter.app"
  executables=("$installed/Contents/MacOS/ZFilter")
  legacy="$HOME/Applications/Filter.app"
  if [[ -f "$legacy/Contents/Info.plist" ]] && [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$legacy/Contents/Info.plist") == studio.archicyan.filter ]]; then
    executables+=("$legacy/Contents/MacOS/Filter")
  fi
  /usr/bin/python3 - "${executables[@]}" <<'PY'
import os,signal,subprocess,sys,time
for line in subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines():
    parts=line.strip().split(None,1)
    if len(parts)==2 and any(parts[1]==path or parts[1].startswith(path+' ') for path in sys.argv[1:]):
        pid=int(parts[0]); os.kill(pid,signal.SIGTERM)
        for _ in range(50):
            try: os.kill(pid,0)
            except ProcessLookupError: break
            time.sleep(.1)
        else: raise RuntimeError('ZFilter has not exited; installation stopped')
PY
  ditto "$APP" "$installed"
  touch "$installed"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed"
  if [[ $# -gt 1 ]]; then
    open "$installed" --args "${@:2}"
  else
    open "$installed"
  fi
fi
printf 'Built: %s\n' "$APP"
