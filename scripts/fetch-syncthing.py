#!/usr/bin/env python3
"""Fetch a pinned upstream engine; verify SHA256 against its HTTPS release manifest."""
from pathlib import Path
import hashlib, io, subprocess, tempfile, zipfile

VERSION = 'v2.1.7'
NAME = f'syncthing-macos-universal-{VERSION}.zip'
BASE = f'https://github.com/syncthing/syncthing/releases/download/{VERSION}/'
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='vaultsync-download-') as directory:
    directory = Path(directory)
    for name in ['sha256sum.txt.asc', NAME]:
        subprocess.run(['/usr/bin/curl', '-fLsS', '--connect-timeout', '15', '--max-time', '120',
                        '--retry', '2', '-o', str(directory / name), BASE + name], check=True)
    manifest = (directory / 'sha256sum.txt.asc').read_text()
    expected = next(line.split()[0] for line in manifest.splitlines() if line.endswith(NAME))
    data = (directory / NAME).read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise SystemExit('SHA256 mismatch; engine was not installed')
    destination = ROOT / 'Resources'
    destination.mkdir(exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for name in archive.namelist():
            if name.endswith('/syncthing'):
                executable = destination / 'syncthing'
                executable.write_bytes(archive.read(name)); executable.chmod(0o755)
            if name.endswith('/LICENSE.txt'):
                (destination / 'SYNCTHING-LICENSE.txt').write_bytes(archive.read(name))
    (destination / 'SYNCTHING-VERSION.txt').write_text(f'{VERSION}\n{NAME}\nSHA256 {expected}\n{BASE}{NAME}\n')
    (destination / 'SHA256SUMS.asc').write_text(manifest)
    print('Downloaded and SHA256-verified', NAME)
