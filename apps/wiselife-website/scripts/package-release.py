"""Build a static public-only release. This script does not deploy it."""
import hashlib
import json
import os
import shutil
import tarfile
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[1]
release = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-hd-v2'
workspace = Path('/tmp') / ('wiselife-' + release)
public = workspace / 'public'
public.mkdir(parents=True)
extensions = {'.html', '.css', '.js', '.webp', '.svg', '.png', '.jpg', '.jpeg', '.mp4', '.vtt', '.woff', '.woff2', '.ico'}
hashes = {}
for source in sorted(root.rglob('*')):
    if not source.is_file():
        continue
    relative = source.relative_to(root)
    parts = set(relative.parts)
    # One public design-reference image is required by the comparison viewer.
    reference = str(relative) == 'design-preview-v2/evidence/reference.png'
    if any(part.startswith('.') for part in relative.parts):
        continue
    if not reference and parts.intersection({'docs', 'scripts', 'Tests', 'evidence', 'node_modules', '__pycache__'}):
        continue
    if source.suffix not in extensions and not ('LICENSE' in source.name and source.suffix in {'.txt', ''}):
        continue
    if str(relative).startswith('design-preview-v2/assets/hd/') and source.suffix == '.png':
        continue  # Full-resolution PNG masters are reproducible; serve optimized WebP.
    if source.is_symlink():
        raise ValueError(f'Unexpected public symlink: {relative}')
    destination = public / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o644)
    hashes[str(relative)] = hashlib.sha256(destination.read_bytes()).hexdigest()
for directory in public.rglob('*'):
    if directory.is_dir():
        directory.chmod(0o755)
assert (public / 'index.html').read_bytes() == (public / 'index-next.html').read_bytes()
manifest = workspace / 'SHA256SUMS'
manifest.write_text(''.join(f'{digest}  {name}\n' for name, digest in hashes.items()))
archive = workspace / (release + '.tar.gz')
with tarfile.open(archive, 'w:gz') as bundle:
    for name in hashes:
        bundle.add(public / name, arcname=name, recursive=False)
result = {'release': release, 'workspace': str(workspace), 'archive': str(archive),
          'manifest': str(manifest), 'files': len(hashes), 'bytes': sum((public / name).stat().st_size for name in hashes),
          'archiveSHA256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'homepageSHA256': hashes['index.html']}
if os.environ.get('WISELIFE_PREVIOUS_RELEASE'):
    result['previousRelease'] = os.environ['WISELIFE_PREVIOUS_RELEASE']
(workspace / 'release.json').write_text(json.dumps(result, indent=2) + '\n')
evidence = Path(os.environ.get('WISELIFE_VERIFY_OUTPUT', root / 'docs/verification/hd-v2-20261031'))
evidence.mkdir(parents=True, exist_ok=True)
(evidence / 'release.json').write_text(json.dumps(result, indent=2) + '\n')
(evidence / 'public-sha256.json').write_text(json.dumps(hashes, indent=2) + '\n')
print(json.dumps(result, indent=2))
