#!/usr/bin/env python3
"""Verify an abrupt owner exit cannot leave the engine or its executable mount held open."""
from pathlib import Path
import json, os, signal, subprocess, tempfile, time

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.build' / 'work'
WORK.mkdir(parents=True, exist_ok=True)
BUILD = WORK / 'build'
for product in ['VaultSyncEngineHost','VaultSyncCLI']:
    subprocess.run(['swift','build','--scratch-path',str(BUILD),'--product',product],cwd=ROOT,check=True)
binary = Path(subprocess.check_output(['swift','build','--scratch-path',str(BUILD),'--show-bin-path'],cwd=ROOT,text=True).strip())/'VaultSyncCLI'
home = Path(tempfile.mkdtemp(prefix='lifecycle-check-',dir=WORK))
def exists(pid):
    try: os.kill(pid,0); return True
    except ProcessLookupError: return False
def wait(predicate, label, seconds=15):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if predicate():return
        time.sleep(.1)
    raise RuntimeError('timeout: '+label)
last_identity=None
for mode in ['kill','stop-host','normal']:
    ready=home/(mode+'-ready.json');stop=home/(mode+'-stop')
    with (home/(mode+'.log')).open('w') as log:
        owner=subprocess.Popen([str(binary),'transport-daemon','--home',str(home),'--engine',str(ROOT/'Resources/syncthing'),
            '--api-port','29784','--sync-port','33784','--ready',str(ready),'--stop',str(stop)],stdout=log,stderr=log)
        record=home/'engine/engine-host.json'
        try:
            wait(lambda:ready.exists() or owner.poll() is not None,'owner ready')
            if owner.poll() is not None:raise RuntimeError((home/(mode+'.log')).read_text())
            data=json.loads(record.read_text());assert data['ownerPID']==owner.pid
            identity=json.loads(ready.read_text())['deviceID']
            if last_identity:assert identity==last_identity
            last_identity=identity
            if mode=='kill':os.kill(owner.pid,signal.SIGKILL)
            elif mode=='stop-host':
                os.kill(data['hostPID'],signal.SIGTERM)
                wait(lambda:not exists(data['hostPID']) and not exists(data['enginePID']),'explicit engine stop')
                assert owner.poll() is None
                stop.touch()
            else:stop.touch()
            owner.wait(timeout=10)
            wait(lambda:not exists(data['hostPID']) and not exists(data['enginePID']),'engine host and worker exit')
            wait(lambda:not record.exists(),'ownership record removed')
            print('PASS '+mode+' owner exit removes host + worker and releases state',flush=True)
        finally:
            if owner.poll() is None:owner.kill();owner.wait()
print('PASS restart reuses device identity after abrupt shutdown')
print('Lifecycle artifacts:',home)
