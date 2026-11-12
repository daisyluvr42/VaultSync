#!/usr/bin/env python3
"""Four real isolated Syncthing processes, over this Mac's Tailscale interface.
No existing Syncthing config or user vault is touched.
"""
import json, os, subprocess, sys, tempfile, time, uuid, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.build' / 'work'
WORK.mkdir(parents=True, exist_ok=True)
BUILD = WORK / 'build'
for product in ['VaultWeaveEngineHost','VaultWeaveCLI']:
    subprocess.run(['swift', 'build', '--scratch-path', str(BUILD), '--product', product], cwd=ROOT, check=True)
binary_path = subprocess.check_output(['swift','build','--scratch-path',str(BUILD),'--show-bin-path'], cwd=ROOT, text=True).strip()
CLI = str(Path(binary_path) / 'VaultWeaveCLI')
ENGINE = str(ROOT / 'Resources/syncthing')
run = Path(tempfile.mkdtemp(prefix='integration-', dir=WORK))
vault_id = str(uuid.uuid4())
nodes = []

def wait(predicate, description, seconds=45):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        for node in nodes:
            if node['process'].poll() is not None:
                raise RuntimeError(f"node {node['index']} exited: {(node['root']/'cli.log').read_text()}")
        try:
            last = predicate()
            if last: return last
        except (OSError, ValueError): pass
        time.sleep(0.25)
    raise RuntimeError(f'timeout: {description}; last={last!r}')

def api(node, method, endpoint):
    key = (node['root']/'engine'/'vaultweave-api-key').read_text()
    req = urllib.request.Request(f"http://127.0.0.1:{node['api']}/rest/{endpoint}", method=method, headers={'X-API-Key':key})
    with urllib.request.urlopen(req, timeout=4) as response:
        data = response.read()
        return json.loads(data) if data else {}

def core(node, command='scan', extra=None, vid=None, vault=None):
    args = [CLI, command, '--vault', str(vault or node['vault']), '--vault-id', vid or vault_id,
            '--objects', str(node['root']/'objects'), '--state', str(node['root']/'state'), '--device', f"node-{node['index']}"]
    result = subprocess.run(args+(extra or []), check=True, capture_output=True, text=True)
    return json.loads(result.stdout)

def revisions(node, vid=None):
    directory = node['root']/'objects'/(vid or vault_id)/'revisions'
    return len(list(directory.glob('*.json')))

try:
    for index in range(4):
        root = run / f'node-{index}'; root.mkdir()
        vault = root/'vault'; vault.mkdir()
        log = (root/'cli.log').open('w')
        node = dict(index=index, root=root, vault=vault, api=28500+index, sync=32500+index, log=log)
        args = [CLI,'transport-daemon','--home',str(root),'--engine',ENGINE,
                '--api-port',str(node['api']),'--sync-port',str(node['sync']),
                '--ready',str(root/'ready.json'),'--stop',str(root/'stop'),
                '--peers-file',str(root/'peers.json'),'--device',f'integration-{index}']
        node['process'] = subprocess.Popen(args, stdout=log, stderr=log)
        nodes.append(node)
    for node in nodes:
        wait(lambda: (node['root']/'ready.json').exists(), 'engine readiness', 20)
        node['identity'] = json.loads((node['root']/'ready.json').read_text())
        assert node['identity']['globalDiscovery'] is False and node['identity']['relays'] is False
    for node in nodes:
        peers = [dict(id=other['identity']['deviceID'], name=f"node-{other['index']}", host=other['identity']['host'], port=other['sync']) for other in nodes if other is not node]
        (node['root']/'peers.json').write_text(json.dumps(peers))
    wait(lambda: all(sum(c.get('connected',False) for c in api(node,'GET','system/connections').get('connections',{}).values()) == 3 for node in nodes), 'four node mesh', 60)
    print('PASS four real engines connected via Tailscale', flush=True)
    a,b,c,d = nodes
    (a['vault']/'note.md').write_text('base\n')
    (a['vault']/'attachment.bin').write_bytes(bytes(range(256))*256)
    core(a)
    for node in [b,c,d]:
        wait(lambda: revisions(node) >= 2, 'initial objects')
        wait(lambda: core(node)['files'] == 2, 'initial materialization')
        assert (node['vault']/'note.md').read_text() == 'base\n'
        assert (node['vault']/'attachment.bin').read_bytes() == (a['vault']/'attachment.bin').read_bytes()
    print('PASS initial notes and binary attachment synchronized', flush=True)
    for node in nodes: api(node,'POST','system/pause')
    for index,node in enumerate(nodes):
        (node['vault']/'note.md').write_text(chr(65+index)+'\n'); core(node)
    for node in [a,b,c]: api(node,'POST','system/resume')
    wait(lambda: len(core(a)['conflicts']) == 1 and len(core(a)['conflicts'][0]['heads']) == 3, 'three offline branches')
    conflict = core(a)['conflicts'][0]
    assert conflict['base']
    merged = run/'merged.md'; merged.write_text('ABC\n')
    assert not core(a,'merge',['--path','note.md','--heads',','.join(conflict['heads']),'--file',str(merged)])['conflicts']
    for node in [b,c]: wait(lambda: (core(node)['conflicts'] == [] and (node['vault']/'note.md').read_text() == 'ABC\n'), 'merge propagation')
    print('PASS offline three-way divergence and confirmed merge', flush=True)
    api(d,'POST','system/resume')
    conflict = wait(lambda: next(iter(core(a)['conflicts']),None), 'late fourth branch')
    assert len(conflict['heads']) == 2 and conflict['base']
    merged.write_text('ABCD\n')
    core(a,'merge',['--path','note.md','--heads',','.join(conflict['heads']),'--file',str(merged)])
    for node in [b,c,d]: wait(lambda: (not core(node)['conflicts'] and (node['vault']/'note.md').read_text() == 'ABCD\n'), 'final convergence')
    print('PASS late fourth device retains ancestry and all four converge', flush=True)
    second_id = str(uuid.uuid4()); a2=a['root']/'second-vault'; b2=b['root']/'second-vault'; a2.mkdir(); b2.mkdir()
    (a2/'another.md').write_text('independent vault\n')
    core(a,vid=second_id,vault=a2)
    wait(lambda: revisions(b,second_id)>0, 'second vault objects')
    wait(lambda: core(b,vid=second_id,vault=b2)['files']==1, 'second vault materialization')
    assert (b2/'another.md').read_text()=='independent vault\n'
    print('PASS multiple independent Vault mappings', flush=True)
    peers = json.loads((a['root']/'peers.json').read_text())
    (a['root']/'peers.json').write_text(json.dumps([peer for peer in peers if peer['id'] != d['identity']['deviceID']]))
    wait(lambda: d['identity']['deviceID'] not in [peer['deviceID'] for peer in api(a,'GET','config')['devices']], 'device revocation')
    wait(lambda: not api(a,'GET','system/connections').get('connections',{}).get(d['identity']['deviceID'],{}).get('connected',False), 'revoked connection closes')
    print('PASS device removal revokes engine sharing', flush=True)
    (run/'RESULT.txt').write_text('PASS: 4 real Syncthing processes, Tailnet mesh, notes, attachment, offline branches, explicit merges, late node, second vault\n')
    print('Integration artifacts:',run)
finally:
    for node in nodes: (node['root']/'stop').touch()
    for node in nodes:
        try: node['process'].wait(timeout=12)
        except subprocess.TimeoutExpired: node['process'].terminate()
        node['log'].close()
