# SPDX-License-Identifier: MIT
import fcntl
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
sys.dont_write_bytecode = True
from pathlib import Path

implementation = Path(__file__).resolve().parent
config = json.loads((implementation / 'application.json').read_text())
from common import load, user_state
config, identity = load(implementation)
state = user_state() / identity
state.mkdir(parents=True, exist_ok=True)
for field in ['sdk', 'installable']:
    subprocess.run([config['nixBin'] + '/nix-store', '--realise', config[field], '--add-root', str(state / field), '--indirect'], check=True, stdout=subprocess.DEVNULL)
program = config['installable'] + '/bin/' + config['program']
environment = os.environ.copy()
os.environ['PATH'] = config['nixBin'] + ':' + os.environ.get('PATH', '')
if config.get('hardware'):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('engine', implementation / 'engine.py')
    engine = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(engine)
    manifest = engine.validate({'name': 'bootc-hardware', 'version': '1', 'priority': 5,
        'installable': config['installable'], 'hardware': config['hardware']}, 'bootc-impurifier')
    with (state / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        snapshot = engine.hardware_snapshots([manifest], state)['bootc-hardware']
        subprocess.run(['nix-store', '--realise', snapshot, '--add-root', str(state / ('library-' + hashlib.sha256(snapshot.encode()).hexdigest())), '--indirect'], check=True, stdout=subprocess.DEVNULL)
    environment['LD_LIBRARY_PATH'] = snapshot + (':' + environment['LD_LIBRARY_PATH'] if environment.get('LD_LIBRARY_PATH') else '')
    if config['hardware'].get('preload'):
        environment['LD_PRELOAD'] = ' '.join(snapshot + '/' + name for name in config['hardware']['preload'])
os.execve(program, [program, *sys.argv[1:]], environment)
