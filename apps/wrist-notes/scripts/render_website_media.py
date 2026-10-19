"""Build local website media from capture_website_media.mjs output.

Requires Pillow and ffmpeg. Pass --font for a CJK font on non-macOS machines.
"""
import argparse
import subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--font', type=Path)
parser.add_argument('--scratch', type=Path, default=Path('/private/tmp/wiselife-website-media'))
args = parser.parse_args()
assets = Path(__file__).resolve().parents[1] / 'prototype/assets/wiselife'
font_path = args.font or next(Path('/System/Library/AssetsV2').glob('**/PingFang.ttc'), None)
if font_path is None:
    parser.error('Pass --font pointing to a Chinese-capable .ttf or .ttc file.')
args.scratch.mkdir(parents=True, exist_ok=True)
font = lambda size: ImageFont.truetype(str(font_path), size)
canvas = Image.new('RGB', (1280, 720), '#eaf0f5')
draw = ImageDraw.Draw(canvas)
draw.text((80, 72), 'WiseLife', font=font(34), fill='#335f7a')
draw.text((80, 210), '把一天，', font=font(64), fill='#202a30')
draw.text((80, 300), '看得更清楚。', font=font(64), fill='#335f7a')
draw.text((84, 420), '回看记录，追问细节。', font=font(23), fill='#65727b')
draw.text((84, 461), '为想做的事，留一个下一步。', font=font(23), fill='#65727b')
draw.text((84, 630), '原型操作演示 / 示例数据', font=font(16), fill='#65727b')
draw.rounded_rectangle((824, 8, 1160, 713), radius=34, fill='#34434c')
canvas.save(args.scratch / 'film-background.png')
mask = Image.new('L', (320, 692), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 319, 691), radius=27, fill=255)
mask.save(args.scratch / 'screen-mask.png')
for name in ['day-overview', 'note-summary', 'note-transcript', 'ai-answer', 'ring-connected', 'hardware-connected', 'thought-transcript']:
    source = args.scratch / f'{name}.png'
    Image.open(source).convert('RGB').save(assets / f'{name}.webp', quality=87, method=6)
poster = canvas.copy()
poster.paste(Image.open(assets / 'day-overview.webp').resize((320, 692), Image.Resampling.LANCZOS), (832, 14), mask)
poster.save(assets / 'film-poster.webp', quality=88, method=6)
subprocess.run([
    'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
    '-loop', '1', '-framerate', '25', '-i', str(args.scratch / 'film-background.png'),
    '-ss', '1.9', '-i', str(args.scratch / 'walkthrough-raw.webm'),
    '-loop', '1', '-framerate', '25', '-i', str(args.scratch / 'screen-mask.png'),
    '-filter_complex', '[1:v]scale=320:692,setsar=1[screen];[screen][2:v]alphamerge[rounded];[0:v][rounded]overlay=832:14:shortest=1,format=yuv420p[out]',
    '-map', '[out]', '-an', '-c:v', 'libx264', '-preset', 'fast', '-crf', '23', '-t', '27',
    '-movflags', '+faststart', str(assets / 'wiselife-walkthrough.mp4')
], check=True)
print('Rendered WebP screenshots, poster and 27-second MP4.')
