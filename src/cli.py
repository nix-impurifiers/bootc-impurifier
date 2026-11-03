# SPDX-License-Identifier: MIT
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
from common import ROOTS, load
from prune import deployments, native_status, prune

parser = argparse.ArgumentParser()
commands = parser.add_subparsers(dest='operation', required=True)
commands.add_parser('prepare')
commands.add_parser('prune').add_argument('--owner')
args = parser.parse_args()
if os.geteuid() != 0:
    parser.error('image preparation and pruning require root')
if args.operation == 'prune':
    prune(args.owner)
    sys.exit(0)
status = native_status()
roots = deployments(status)
selected = roots.get(0, roots.get(2 if status.get('rollbackQueued') else 1))
if selected is None:
    parser.error('no native staged or booted OSTree deployment')
nix_store = shutil.which('nix-store')
if not nix_store:
    parser.error('the host must provide Nix')
ROOTS.mkdir(parents=True, exist_ok=True)
with (ROOTS / '.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    if selected.is_dir():
        for implementation in sorted(selected.iterdir()):
            config, identity = load(implementation)
            with tempfile.TemporaryDirectory(prefix='.prepare-', dir=ROOTS) as staged:
                for field, cache_name in [('sdk', 'sdk-cache'), ('installable', 'cache')]:
                    command = [nix_store, '--realise', config[field], '--add-root', staged + '/' + field]
                    cache = implementation / cache_name
                    if cache.is_dir():
                        command += ['--option', 'substituters', cache.as_uri(), '--option', 'require-sigs', 'false']
                    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
                (Path(staged) / 'source.json').write_text(json.dumps({'name': config['name'], 'identity': identity}))
                if not (ROOTS / identity).exists():
                    os.rename(staged, ROOTS / identity)
prune()
