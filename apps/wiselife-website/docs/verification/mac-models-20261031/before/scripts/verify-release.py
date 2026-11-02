"""Read-only HTTPS verification of the latest packaged WiseLife release."""
import hashlib
import json
import os
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
out = Path(os.environ.get('WISELIFE_VERIFY_OUTPUT', root / 'docs/verification/hd-v2-20261031'))
manifest = json.loads((out / 'public-sha256.json').read_text())
release = json.loads((out / 'release.json').read_text())
base = 'https://wiselife.karama.cloud'
results = []
for name in ['index.html', 'index-next.html', 'design-preview-v2/index.html',
             'design-preview-v2/style.css', 'design-preview-v2/site.js',
             'design-preview-v2/assets/hd/iphone-day.webp',
             'design-preview-v2/assets/hd/mac-knowledge.webp',
             'design-preview-v2/assets/hd/hero-reference.webp',
             'design-preview-v2/assets/watch-hardware.svg',
             'assets/brand/app-icon.svg', 'product-demos/iphone/index.html',
             'product-demos/mac/index.html']:
    if name not in manifest:
        continue
    with urllib.request.urlopen(base + '/' + name, timeout=30) as response:
        data = response.read()
        actual = hashlib.sha256(data).hexdigest()
        assert actual == manifest[name], name
        results.append({'path': name, 'status': response.status, 'sha256': actual, 'bytes': len(data)})
request = urllib.request.Request(base + '/assets/wiselife/wiselife-walkthrough.mp4',
                                 headers={'Range': 'bytes=0-1023'})
with urllib.request.urlopen(request, timeout=30) as response:
    data = response.read()
    assert response.status == 206 and len(data) == 1024
    video = {'status': response.status, 'bytes': len(data), 'contentRange': response.headers.get('Content-Range')}
with urllib.request.urlopen(base + '/', timeout=30) as response:
    homepage = {'status': response.status, 'url': response.geturl(), 'sha256': hashlib.sha256(response.read()).hexdigest()}
    assert homepage['sha256'] == manifest['index.html']
result = {'status': 'PASS', 'homepage': homepage, 'verifiedPublicHashes': results,
          'videoRange': video, 'release': release['release'], 'previousRelease': release.get('previousRelease', '20261031T060113Z'),
          'publicFilesVerifiedOnServer': release['files']}
(out / 'deployment.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
