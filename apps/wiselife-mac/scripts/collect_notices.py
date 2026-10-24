#!/usr/bin/env python3
"""Bundle the exact resolved dependencies' licenses for app distribution."""
import json, pathlib
root = pathlib.Path(__file__).resolve().parents[1]
pins = json.loads((root/'Package.resolved').read_text())['pins']
parts = ['WiseLife Mac Companion — Third-party notices\n\nModel catalog: mlx-community/Qwen3-4B-4bit and mlx-community/Qwen3-1.7B-4bit.\nModel cards declare Apache-2.0; immutable revisions and hashes are in ModelCatalog.json.\nModel weights are not bundled.\n']
for pin in pins:
    path = root/'.build/checkouts'/pin['identity']
    candidates = [p for p in path.iterdir() if p.is_file() and p.name.lower() in ['license', 'license.txt', 'license.md', 'copying']]
    if not candidates:
        raise RuntimeError('Missing license: '+pin['identity'])
    parts += [f"\n{'='*70}\n{pin['identity']} {pin['state'].get('version', '')} @ {pin['state']['revision']}\n{pin['location']}\n\n", candidates[0].read_text()]
(root/'Resources/ThirdPartyNotices.txt').write_text('\n'.join(parts))
print('Collected', len(pins), 'dependency licenses')
