#!/bin/zsh
set -eu
task_root="${0:A:h:h}"
task_work="$task_root/.build/work"
task_release="$task_root/dist"
task_build="${task_work}/build"
task_destination="${task_release}/VaultSync.app"
task_stage="$(mktemp -d /private/tmp/vaultsync-build.XXXXXX)"
trap 'rm -rf "$task_stage"' EXIT
task_output="$task_stage/VaultSync.app"
cd "$task_root"
mkdir -p "$task_work" "$task_release"
if [[ ! -x Resources/syncthing ]]; then python3 scripts/fetch-syncthing.py; fi
task_configuration="${1:-release}"
swift build -c "$task_configuration" --scratch-path "$task_build" --product VaultSync
swift build -c "$task_configuration" --scratch-path "$task_build" --product VaultSyncEngineHost
task_bin="$(swift build -c "$task_configuration" --scratch-path "$task_build" --show-bin-path)"
mkdir -p "$task_output/Contents/MacOS" "$task_output/Contents/Helpers" "$task_output/Contents/Resources"
cp "$task_bin/VaultSync" "$task_output/Contents/MacOS/VaultSync"
cp "$task_bin/VaultSyncEngineHost" "$task_output/Contents/Helpers/VaultSyncEngineHost"
if [[ "$task_configuration" == "release" ]]; then
    if [[ "$(uname -m)" == "arm64" ]]; then task_other="x86_64"; task_cross_build="${task_work}/intel"; else task_other="arm64"; task_cross_build="${task_work}/apple-silicon"; fi
    swift build -c release --triple "${task_other}-apple-macosx13.0" --scratch-path "$task_cross_build" --product VaultSync
    swift build -c release --triple "${task_other}-apple-macosx13.0" --scratch-path "$task_cross_build" --product VaultSyncEngineHost
    task_cross_bin="$(swift build -c release --triple "${task_other}-apple-macosx13.0" --scratch-path "$task_cross_build" --show-bin-path)"
    lipo -create "$task_bin/VaultSync" "$task_cross_bin/VaultSync" -output "$task_output/Contents/MacOS/VaultSync"
    lipo -create "$task_bin/VaultSyncEngineHost" "$task_cross_bin/VaultSyncEngineHost" -output "$task_output/Contents/Helpers/VaultSyncEngineHost"
    # Swift's debug map contains absolute source and object paths. Strip it before signing.
    for task_binary in "$task_output/Contents/MacOS/VaultSync" "$task_output/Contents/Helpers/VaultSyncEngineHost"; do
        /usr/bin/strip -S "$task_binary"
        if LC_ALL=C /usr/bin/strings -a "$task_binary" |
            /usr/bin/grep -F -e "$task_root/" -e "$task_build/" -e "$task_cross_build/" >/dev/null; then
            print -u2 "Build paths remain in ${task_binary:t}"
            exit 1
        fi
    done
fi
cp Resources/syncthing "$task_output/Contents/Helpers/syncthing"
cp Resources/SYNCTHING-LICENSE.txt Resources/SYNCTHING-VERSION.txt "$task_output/Contents/Resources/"
if [[ ! -f Resources/VaultSync.icns ]]; then
    swift scripts/make-icon.swift "${task_work}/VaultSync.iconset"
    iconutil -c icns "${task_work}/VaultSync.iconset" -o Resources/VaultSync.icns
fi
cp Resources/VaultSync.icns "$task_output/Contents/Resources/"
cat > "$task_output/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VaultSync</string>
<key>CFBundleIdentifier</key><string>app.vaultsync.mac</string>
<key>CFBundleName</key><string>VaultSync</string>
<key>CFBundleDisplayName</key><string>VaultSync</string>
<key>CFBundleIconFile</key><string>VaultSync</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.6</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>VaultSync 通过 Tailscale 与你的其他 Mac 同步文库。</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$task_output/Contents/Helpers/syncthing"
codesign --force --sign - "$task_output/Contents/Helpers/VaultSyncEngineHost"
xattr -dr com.apple.FinderInfo "$task_output" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$task_output" 2>/dev/null || true
codesign --force --sign - "$task_output"
codesign --verify --deep --strict "$task_output"
if [[ -d "$task_destination" ]]; then mv "$task_destination" "$task_stage/Previous.app"; fi
ditto --norsrc "$task_output" "$task_destination"
print "$task_destination"
