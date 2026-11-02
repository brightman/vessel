"""Use the selected V2 page as both public homepage entries, with correct paths."""
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / 'design-preview-v2/index.html').read_text()

def resolve(match):
    attribute, value = match.groups()
    if value.startswith('../'):
        value = value[3:]
    elif value.startswith(('assets/', 'style.css', 'site.js')):
        value = 'design-preview-v2/' + value
    return f'{attribute}="{value}"'

source = re.sub(r'(href|src)="([^"]+)"', resolve, source)
source = re.sub(r'srcset="([^"]+)"', lambda match:
    'srcset="' + match.group(1).replace('assets/', 'design-preview-v2/assets/') + '"', source)
for name in ('index.html', 'index-next.html'):
    (root / name).write_text(source)
print('Synchronized index.html and index-next.html with the selected V2 source.')
