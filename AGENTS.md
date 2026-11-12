# VaultSync development

VaultSync is a native macOS Swift package. Keep build caches and fixtures under `.build/` and packaged apps under `dist/`.

- Use VaultSync consistently for the bundle ID, data directory, transport folder IDs, and Swift modules. Preserve existing immutable revisions and device identity during the one-time upgrade.
- Use isolated temporary vaults and `VAULTSYNC_HOME` for testing.
- Transfer immutable hash-verified objects. Keep device keys, local state, drafts, settings, and engine databases local.
- Capture local edits before applying remote changes. Preserve divergent branches and ancestry, and reject stale merges.
- Call `DirectoryEnumerator.skipDescendants` only on directories. Keep regression coverage for ignored files and neighboring files.
- Keep `AppModel` on the main actor and serialize engine work through `EngineWorkspace`.
- Use explicit Tailscale peer addresses and mutual pairing. Keep public discovery and relays disabled.

```sh
swift run --scratch-path .build/work/build VaultSyncChecks
zsh scripts/package-release.sh
python3 scripts/integration-check.py
python3 scripts/lifecycle-check.py
python3 scripts/startup-check.py
git diff --check
```
