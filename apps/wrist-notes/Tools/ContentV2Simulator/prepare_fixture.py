#!/usr/bin/env python3
"""Copy one recording and its successful inference evidence into a named lab clone.

This is a development import, not WatchConnectivity or a fresh ASR/VAD run.
It never overwrites existing source rows or an audio file with a different hash.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('device', 'fixture', 'audio', 'source-id', 'report', 'database-tool'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', '--json'))['devices']
    device = next(d for group in devices.values() for d in group if d['udid'] == args.device)
    if device['name'] != 'WiseLife Content Lab' or device['state'] != 'Booted':
        raise RuntimeError('Refusing to import outside the booted WiseLife Content Lab clone')
    container = Path(run('xcrun', 'simctl', 'get_app_container', args.device, 'cloud.karama.wisenote', 'data')).resolve()
    report = Path(args.report).resolve()
    report.mkdir(parents=True, exist_ok=True)
    source_key = 'legacyNote:' + args.source_id
    fixture = sqlite3.connect(Path(args.fixture).resolve().as_uri() + '?mode=ro', uri=True)
    fixture.row_factory = sqlite3.Row
    row = fixture.execute('SELECT * FROM audio_processing_sources WHERE source_key=?', (source_key,)).fetchone()
    if not row:
        raise RuntimeError('Exact source not present')
    descriptor = json.loads(row['descriptor'])
    if len(descriptor['ranges']) != 1:
        raise RuntimeError('This import utility accepts an existing single-file recording only')
    expected_hash = descriptor['ranges'][0]['contentHash']
    audio = Path(args.audio).resolve()
    if digest(audio) != expected_hash:
        raise RuntimeError('Original recording hash mismatch')
    destination = container / 'Documents/VoiceNotes/Audio' / (args.source_id + '.m4a')
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if digest(destination) != expected_hash:
            raise RuntimeError('Destination audio differs; no overwrite performed')
    else:
        shutil.copy2(audio, destination)
    db_path = container / 'Library/Application Support/WristNotes/Database/daybook.sqlite3'
    subprocess.run([args.database_tool, 'init', str(db_path)], check=True)
    db = sqlite3.connect(db_path)
    db.execute('PRAGMA foreign_keys=ON')
    backup = sqlite3.connect(report / 'simulator-before-import.sqlite3')
    db.backup(backup)
    backup.close()
    if db.execute('SELECT 1 FROM audio_processing_sources WHERE source_key=?', (source_key,)).fetchone():
        raise RuntimeError('Source already imported; refusing to replace test results')
    jobs = list(fixture.execute('SELECT * FROM audio_processing_jobs WHERE source_key=? AND active=1 ORDER BY core_start,id', (source_key,)))
    asr_coverage, vad_coverage = [], []
    for job in jobs:
        result = json.loads(job['result'])
        if result['asr'] != 'success' or result['vad'] != 'success':
            raise RuntimeError('Fixture must have successful ASR and VAD for each window')
        asr_coverage += result['asrCoverage']
        vad_coverage += result['vadCoverage']
    original_url = descriptor['ranges'][0]['url']

    def relocate(value):
        if isinstance(value, dict):
            return {key: relocate(item) for key, item in value.items()}
        if isinstance(value, list):
            return [relocate(item) for item in value]
        return destination.as_uri() if value == original_url else value

    def insert(table, record, json_fields=()):
        values = dict(record)
        for field in json_fields:
            values[field] = json.dumps(relocate(json.loads(values[field])), ensure_ascii=False).encode()
        columns = ','.join(values)
        placeholders = ','.join('?' for _ in values)
        db.execute(f'INSERT INTO {table} ({columns}) VALUES ({placeholders})', tuple(values.values()))

    spans, activities = [], []
    with db:
        note = fixture.execute('SELECT * FROM voice_notes WHERE id=?', (args.source_id,)).fetchone()
        if note is None:
            raise RuntimeError('Source note is missing')
        insert('voice_notes', note)
        insert('audio_processing_sources', row, ('descriptor',))
        for job in jobs:
            insert('audio_processing_jobs', job, ('window',))
            for text in fixture.execute('SELECT * FROM audio_transcript_spans WHERE job_id=? ORDER BY position', (job['id'],)):
                insert('audio_transcript_spans', text)
                spans.append(dict(id=job['id'] + ':' + str(text['position']), start=text['start'], end=text['end'], text=text['text']))
            for activity in fixture.execute('SELECT * FROM audio_activity_intervals WHERE job_id=? ORDER BY position', (job['id'],)):
                insert('audio_activity_intervals', activity)
                activities.append({key: activity[key] for key in ('start', 'end', 'kind')})
    spans.sort(key=lambda span: (span['start'], span['end'], span['id']))
    audio_range = descriptor['ranges'][0]
    duration = (audio_range['endFrame'] - audio_range['startFrame']) / audio_range['sampleRate']
    input_value = dict(sourceID=source_key, sourceRevision=str(row['revision']), duration=duration,
                       spans=spans, asrCoverage=asr_coverage, vadCoverage=vad_coverage,
                       activities=activities, boundaries=[])
    input_path = report / 'input.json'
    input_path.write_text(json.dumps(input_value, ensure_ascii=False), encoding='utf-8')
    manifest = dict(device=args.device, simulatorName=device['name'], container=str(container), database=str(db_path),
                    sourceID=source_key, audio=str(destination), sha256=digest(destination), duration=duration,
                    jobCount=len(jobs), transcriptRows=len(spans), transcriptCharacters=sum(len(x['text']) for x in spans),
                    activityRows=len(activities), capturedAt=descriptor['capturedAt'], cancelled=row['cancelled'],
                    asrProvenance='Reused successful physical iPhone ASR, not rerun in simulator',
                    vadProvenance='Reused successful Mac VAD rerun with FP16 probability fix',
                    fixture=str(Path(args.fixture).resolve()), inputSHA256=digest(input_path))
    (report / 'import-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    db.close()
    fixture.close()
    print(json.dumps({key: manifest[key] for key in ('simulatorName', 'sha256', 'duration', 'jobCount', 'transcriptRows', 'transcriptCharacters')}))


if __name__ == '__main__':
    main()
