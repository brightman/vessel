#!/usr/bin/env python3
"""Maintainer tool: explicitly refresh model pins. Downloads metadata, never weights."""
import concurrent.futures, hashlib, json, pathlib, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
REPOS = ['mlx-community/Qwen3-4B-4bit', 'mlx-community/Qwen3-1.7B-4bit']
def read(url):
    return urllib.request.urlopen(url, timeout=60).read()
def model(repo):
    metadata = json.loads(read(f'https://huggingface.co/api/models/{repo}?blobs=true'))
    assert metadata['cardData']['license'] == 'apache-2.0'
    revision = metadata['sha']
    files = []
    for item in metadata['siblings']:
        name = item['rfilename']
        if name.startswith('.') or '/' in name or not name.endswith(('.json', '.txt', '.safetensors', '.md')):
            continue
        digest = item.get('lfs', {}).get('sha256')
        if digest is None:
            content = read(f'https://huggingface.co/{repo}/resolve/{revision}/{name}')
            assert len(content) == item['size']
            digest = hashlib.sha256(content).hexdigest()
        files.append(dict(name=name, bytes=item['size'], sha256=digest))
    return dict(id=repo, name=repo.split('/')[1].replace('-4bit', ' · 4-bit'), revision=revision,
                license='Apache-2.0', source=f'https://huggingface.co/{repo}',
                acceptance='engineering-preview', files=files)
models = list(concurrent.futures.ThreadPoolExecutor(max_workers=2).map(model, REPOS))
(ROOT/'Sources/CompanionCore/ModelCatalog.json').write_text(json.dumps(models, ensure_ascii=False, indent=2)+'\n')
print('Pinned', [(m['id'], m['revision']) for m in models])
