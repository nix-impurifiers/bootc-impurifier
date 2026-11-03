# SPDX-License-Identifier: MIT
import hashlib
import json
import os
from pathlib import Path
import re

APPLICATIONS = Path('/usr/share/bootc-impurifier/apps')
ROOTS = Path('/nix/var/nix/gcroots/bootc-impurifier')

def name(value):
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.+-]*', value):
        raise ValueError('invalid application or command name')
    return value

def load(implementation):
    raw = (implementation / 'application.json').read_bytes()
    config = json.loads(raw)
    name(config['name'])
    name(config['program'])
    for field in ['installable', 'sdk']:
        if not re.fullmatch(r'/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+', config[field]) or config[field].endswith('.drv'):
            raise ValueError('expected a Nix output path')
    return config, hashlib.sha256(raw).hexdigest()

def user_state():
    return Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'bootc-impurifier'
