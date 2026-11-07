#!/usr/bin/env python3
"""Assemble a mode-specific prompt locally. Does not call an AI or read user data."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--mode', required=True, choices=['daily', 'training', 'meal', 'review', 'assistant'])
args = parser.parse_args()
skill = Path(__file__).resolve().parents[1]
root = skill.parents[1]
entry = (skill / 'SKILL.md').read_text()
body = entry.split('---', 2)[2].strip()
selected = {'daily':['training', 'nutrition'], 'training':['training'], 'meal':['nutrition'], 'review':['review'], 'assistant':['training', 'nutrition', 'review']}[args.mode]
parts = ['# Runtime mode: ' + args.mode, body, (skill / 'references/data-contract.md').read_text()]
for name in selected:
    parts.append((skill / ('references/' + name + '.md')).read_text())
schema_name = 'assistant-response.schema.json' if args.mode == 'assistant' else 'coach-response.schema.json'
schema = json.loads((root / 'contracts' / schema_name).read_text())
parts.append('# Required response schema\n' + json.dumps(schema, ensure_ascii=False, indent=2))
parts.append('Only use tools actually registered by the host. A listed interface is not an available tool. Do not claim data access or writes without real results.')
print('\n\n'.join(parts))
