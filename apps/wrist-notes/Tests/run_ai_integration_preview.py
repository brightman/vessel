#!/usr/bin/env python3
"""Run the installed, signed simulator preview against a local synthetic AI service."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--device', required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
bundle = 'com.vessel.wristnotes.preview'

def simctl(*command, env=None):
    return subprocess.check_output(['xcrun', 'simctl', *command], env=env, text=True).strip()

with tempfile.TemporaryDirectory(prefix='wristnotes-ai-fixture-') as scratch:
    request_file = Path(scratch) / 'requests.json'
    server = subprocess.Popen(['python3', str(Path(__file__).with_name('ai_fixture_server.py')), str(request_file)], stdout=subprocess.PIPE, text=True)
    try:
        port = int(server.stdout.readline().strip())
        container = Path(simctl('get_app_container', args.device, bundle, 'data'))
        result_file = container / 'Documents/ai-integration-result.json'
        result_file.unlink(missing_ok=True)
        environment = dict(os.environ, SIMCTL_CHILD_WN_PREVIEW_SCREEN='summary', SIMCTL_CHILD_WN_TEST_BASE_URL=f'http://localhost:{port}/v1')
        simctl('launch', '--terminate-running-process', args.device, bundle, env=environment)
        deadline = time.monotonic() + 45
        while not result_file.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        result = json.loads(result_file.read_text())
        requests = json.loads(request_file.read_text())
        expected = [
            {'fixed_probe': True, 'summary_text': False, 'auth_failure': False},
            {'fixed_probe': False, 'summary_text': True, 'auth_failure': False},
            {'fixed_probe': True, 'summary_text': False, 'auth_failure': True},
        ]
        result['request_contract_passed'] = requests == expected
        result['ok'] = result['ok'] and result['request_contract_passed']
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False))
        if not result['ok']:
            raise SystemExit(1)
    finally:
        server.terminate()
        server.wait(timeout=5)
