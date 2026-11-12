#!/bin/zsh
set -eu
task_root="${0:A:h:h}"
task_release="$task_root/dist"
cd "$task_root"
zsh scripts/build-app.sh
# Stage outside Documents' File Provider metadata to verify exactly the archive's contents.
task_stage="$(mktemp -d /private/tmp/vaultsync-release.XXXXXX)"
trap 'rm -rf "$task_stage"' EXIT
ditto --norsrc "$task_release/VaultSync.app" "$task_stage/VaultSync.app"
xattr -dr com.apple.FinderInfo "$task_stage/VaultSync.app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$task_stage/VaultSync.app" 2>/dev/null || true
codesign --verify --deep --strict "$task_stage/VaultSync.app"
task_archive="$task_release/VaultSync-0.2.6.zip"
ditto -c -k --norsrc --keepParent "$task_stage/VaultSync.app" "$task_archive"
mkdir "$task_stage/verify"
ditto -x -k "$task_archive" "$task_stage/verify"
codesign --verify --deep --strict "$task_stage/verify/VaultSync.app"
for task_binary in Contents/MacOS/VaultSync Contents/Helpers/VaultSyncEngineHost Contents/Helpers/syncthing; do
    lipo "$task_stage/verify/VaultSync.app/$task_binary" -verify_arch arm64 x86_64
done
(
    cd "$task_release"
    shasum -a 256 VaultSync-0.2.6.zip > VaultSync-0.2.6.sha256
)
print "Verified archive: $task_archive"
