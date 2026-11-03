# SPDX-License-Identifier: MIT
import json
import re
import shutil
import sys
sys.dont_write_bytecode = True
from common import user_state
retained = set(json.loads(sys.argv[1]))
root = user_state()
if root.is_dir():
    for state in root.iterdir():
        if re.fullmatch('[0-9a-f]{64}', state.name) and state.name not in retained:
            shutil.rmtree(state)
