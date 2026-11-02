"""Optimize genuine prototype captures and licensed originals for the website.

Usage: python3 scripts/prepare-hd-assets.py --photos /path/to/downloads
Original photo filenames: hero.jpg, work.jpg, rhythm.jpg, remember.jpg.
Source URLs and licenses: design-preview-v2/assets/hd/sources.json.
"""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageOps

root = Path(__file__).resolve().parents[1]
out = root / 'design-preview-v2/assets/hd'
parser = argparse.ArgumentParser()
parser.add_argument('--photos', type=Path)
parser.add_argument('--screens', nargs='+', help='Only optimize these named screenshot PNG masters.')
args = parser.parse_args()

for name in args.screens or ('iphone-day', 'iphone-ai', 'mac-knowledge', 'watch-recording', 'mac-models'):
    with Image.open(out / f'{name}.png') as original:
        original.save(out / f'{name}.webp', 'WEBP', quality=96, method=6)

if args.photos:
    for name in ('hero', 'work', 'rhythm', 'remember'):
        original = ImageOps.exif_transpose(Image.open(args.photos / f'{name}.jpg')).convert('RGB')
        widths = (1200, 2400) if name == 'hero' else (800, 1600, 3200) if name == 'rhythm' else (800, 1600)
        for width in widths:
            if original.width < width:
                raise ValueError(f'{name}.jpg must be at least {width}px wide; do not upscale photos.')
            height = round(original.height * width / original.width)
            original.resize((width, height), Image.Resampling.LANCZOS).save(
                out / f'{name}-{width}.webp', 'WEBP', quality=88, method=6)

manifest = {}
for file in sorted(out.glob('*.webp')):
    with Image.open(file) as image:
        manifest[file.name] = {'width': image.width, 'height': image.height, 'bytes': file.stat().st_size}
(out / 'dimensions.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
