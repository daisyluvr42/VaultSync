#!/usr/bin/env python3
"""Exercise auto-start + connection polling on isolated GUI processes, with UI queue assertions."""
import json, os, plistlib, shutil, subprocess, tempfile, time, urllib.request, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.build' / 'work'
WORK.mkdir(parents=True, exist_ok=True)
SOURCE_APP = ROOT / 'dist' / 'VaultSync.app'
run = Path(tempfile.mkdtemp(prefix='startup-check-', dir=WORK))
for index in range(6):
    home = run / str(index); home.mkdir()
    config = dict(localID=str(uuid.uuid4()), deviceName='Isolated startup check', vaults=[], peers=[],
                  offeredVaults=[], transportEnabled=True, scanInterval=3)
    (home/'settings.json').write_text(json.dumps(config))
    env = {k:v for k,v in os.environ.items() if k not in {'SHLVL','TERM','TERM_PROGRAM','PS1','TAILSCALE_BE_CLI'}}
    env.update(VAULTSYNC_HOME=str(home), VAULTSYNC_API_PORT=str(29600+index),
               VAULTSYNC_SYNC_PORT=str(33600+index), VAULTSYNC_PAIRING_PORT=str(33700+index))
    # Give QA its own identity and persistent overrides, including any LaunchServices relaunch.
    # Stage outside Documents so File Provider cannot add invalidating FinderInfo metadata.
    qa_stage = Path(tempfile.mkdtemp(prefix='vaultsync-startup-',dir='/private/tmp'))
    qa_app = qa_stage/'VaultSync Startup Check.app'
    subprocess.run(['ditto','--norsrc',str(SOURCE_APP),str(qa_app)],check=True)
    plist = qa_app/'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    info['CFBundleIdentifier'] = 'app.vaultsync.startup-check.'+str(uuid.uuid4())
    info['CFBundleName'] = info['CFBundleDisplayName'] = 'VaultSync Startup Check'
    info['LSEnvironment'] = {k:v for k,v in env.items() if k.startswith('VAULTSYNC_')}
    plist.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign','--force','--sign','-',str(qa_app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    app = qa_app/'Contents/MacOS/VaultSync'
    with (home/'app.log').open('w') as log:
        process = subprocess.Popen([str(app)], env=env, stdout=log, stderr=log)
        def api(method, endpoint):
            key = (home/'Syncthing/vaultsync-api-key').read_text()
            request = urllib.request.Request(f'http://127.0.0.1:{29600+index}/rest/{endpoint}',method=method,headers={'X-API-Key':key})
            with urllib.request.urlopen(request,timeout=2) as response: return response.read()
        try:
            deadline = time.monotonic()+18
            while True:
                if process.poll() is not None: raise RuntimeError(f'app exited {process.returncode}: {(home/"app.log").read_text()}')
                try:
                    if json.loads(api('GET','system/status')).get('myID'): break
                except (OSError, ValueError): pass
                if time.monotonic()>deadline: raise RuntimeError('auto-start did not initialize engine')
                time.sleep(0.15)
            # Allow initial refresh and at least one timer refresh, the original crashing path.
            until = time.monotonic()+4
            while time.monotonic()<until:
                if process.poll() is not None: raise RuntimeError(f'UI process exited ({process.returncode}): {(home/"app.log").read_text()}')
                time.sleep(0.15)
            print(f'PASS auto-start + main-thread connection refresh {index+1}/6',flush=True)
        finally:
            try: api('POST','system/shutdown')
            except (OSError, ValueError): pass
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
            shutil.rmtree(qa_stage)
print('Startup artifacts:', run)
