#!/usr/bin/env python3
"""Human-readable artifacts from validated Swift output, without re-segmenting."""
from pathlib import Path
import argparse
import collections
import datetime as dt
import html
import json


def stamp(seconds):
    value = round(seconds)
    return f'{value // 3600:02}:{value // 60 % 60:02}:{value % 60:02}'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('report')
    parser.add_argument('--output', default='run-1/output.json')
    args = parser.parse_args()
    root = Path(args.report).resolve()
    result = json.loads((root / args.output).read_text())
    manifest = json.loads((root / 'import-manifest.json').read_text())
    origin = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(seconds=manifest['capturedAt'])
    origin = origin.astimezone(dt.timezone(dt.timedelta(hours=8)))
    counts = collections.Counter(x['classification'] for x in result['segments'])
    names = {'meaningful':'有意义内容', 'lowInformation':'低信息', 'pendingConfirmation':'待确认'}
    lines = ['# 6 小时 42 分录音：模拟器分段结果', '',
             f"- 原始时长：{stamp(manifest['duration'])}；音频 SHA256 已核对。",
             '- 在 WiseLife Content Lab 模拟器中运行共享 Swift 策略；使用已配置的 Doubao-Seed-2.0-mini。',
             '- ASR 复用真机结果；VAD 复用 Mac 修复后的完整结果。此轮没有重新运行语音识别。',
             f"- {len(result['plan']['blocks'])} 个文字块，{len(result['plan']['chapters'])} 个候选章，{sum(x['status']=='verified' for x in result['plan']['gaps'])} 个确认长空白。",
             '- 不使用旧 preview 的人工地点补充或样本 ID 特例。',
             '- 分类：' + '，'.join(f'{names[k]} {v} 段' for k, v in counts.items()) + '。', '',
             '| 序号 | 开始时间 | 原音频位置 | 时长 | 分类 | 主题 |', '| --- | --- | --- | --- | --- | --- |']
    cards = []
    for index, segment in enumerate(result['segments'], 1):
        start = (origin + dt.timedelta(seconds=segment['start'])).strftime('%H:%M:%S')
        duration = stamp(segment['end'] - segment['start'])
        label = names[segment['classification']]
        title = segment['title'].replace('|', '／')
        lines.append(f"| {index:02} | {start} | {stamp(segment['start'])} | {duration} | {label} | {title} |")
        escaped = {key:html.escape(str(segment[key])) for key in ('title','summary','uncertainty')}
        cards.append(f'''<article data-kind="{segment['classification']}"><header><span>{index:02} · {start} · {duration}</span><span>{label}</span></header>
<h2>{escaped['title']}</h2><p>{escaped['summary']}</p><p class="muted">{escaped['uncertainty']}</p>
<button data-start="{segment['start']}" data-end="{segment['end']}">回听此段</button></article>''')
    lines += ['', '## 每段摘要', '']
    for index, segment in enumerate(result['segments'], 1):
        lines += [f"### {index:02} {segment['title']}", '', segment['summary'], '']
        if segment['uncertainty']:
            lines += ['不确定性：' + segment['uncertainty'], '']
    (root / '模拟器分段结果.md').write_text('\n'.join(lines), encoding='utf-8')
    count_text = ' · '.join(f'{names[k]} {v} 段' for k, v in counts.items())
    document = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WiseLife · 模拟器分段结果</title><style>
body{font:16px/1.7 -apple-system,BlinkMacSystemFont,sans-serif;margin:0;background:#f5f5f2;color:#222}main{max-width:900px;margin:auto;padding:42px 24px 140px}h1{font-size:30px;letter-spacing:-1px;line-height:1.3}h2{font-size:20px;margin:12px 0}article{background:white;border:1px solid #e5e5df;border-radius:16px;padding:22px;margin:18px 0}header{display:flex;justify-content:space-between;font-size:13px;color:#686863}.muted{color:#777;font-size:14px}button,select{font:inherit;border:1px solid #ccc;border-radius:8px;padding:8px 14px;background:white;cursor:pointer}button{color:#205d46}footer{position:fixed;bottom:0;background:#fffefbf5;border-top:1px solid #ddd;padding:14px 24px;width:100%;box-sizing:border-box}audio{width:min(100%,900px);display:block;margin:auto}article[hidden]{display:none}
</style><main><p class="muted">WiseLife / Content Lab</p><h1>把 6 小时 42 分，整理成可以回看的内容。</h1>
<p>COUNT</p><p class="muted">真实音频已导入独立模拟器。新 Swift 策略生成结果，ASR/VAD 使用已验证缓存；这里展示本轮模型结果，不包含旧预览中的人工标题修订。</p>
<label>显示 <select id="filter"><option value="meaningful">有意义内容</option><option value="all">全部内容（含低信息与待确认）</option></select></label>
CARDS</main><footer><audio id="player" controls preload="metadata" src="../2026-10-23-6h42m-segmentation/recording.m4a"></audio></footer>
<script>const p=document.getElementById('player');let stopAt=Infinity;function filter(){document.querySelectorAll('article').forEach(a=>a.hidden=document.getElementById('filter').value!=='all'&&a.dataset.kind!=='meaningful')}document.getElementById('filter').onchange=filter;filter();document.querySelectorAll('button[data-start]').forEach(b=>b.onclick=()=>{stopAt=Number(b.dataset.end);p.currentTime=Number(b.dataset.start);p.play()});p.ontimeupdate=()=>{if(p.currentTime>=stopAt)p.pause()};</script></html>'''
    (root / '模拟器分段试听.html').write_text(document.replace('COUNT',html.escape(count_text)).replace('CARDS','\n'.join(cards)), encoding='utf-8')
    print(json.dumps({'segments':len(result['segments']), 'classifications':dict(counts)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
