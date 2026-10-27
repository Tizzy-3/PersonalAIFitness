#!/usr/bin/env python3
import json
import subprocess
import argparse
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--boot', action='store_true', help='Boot and wait for this exact selected simulator before tests or UI capture.')
args = parser.parse_args()

data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
for runtime, devices in data['devices'].items():
    if 'iOS-27-0' in runtime:
        choices = [d for d in devices if d.get('isAvailable') and d.get('name', '').startswith('iPhone')]
        choices.sort(key=lambda d: ('Pro Max' not in d['name'], d['name']))
        if choices:
            selected = choices[0]
            if args.boot:
                if selected.get('state') != 'Booted':
                    subprocess.run(['xcrun', 'simctl', 'boot', selected['udid']], check=True, stdout=sys.stderr)
                subprocess.run(['xcrun', 'simctl', 'bootstatus', selected['udid'], '-b'], check=True, stdout=sys.stderr)
            print(selected['udid'])
            raise SystemExit(0)
raise SystemExit('No iOS 27.0 iPhone Simulator available; do not silently switch runtime.')
