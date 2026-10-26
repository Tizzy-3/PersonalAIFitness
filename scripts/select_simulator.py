#!/usr/bin/env python3
import json
import subprocess

data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
for runtime, devices in data['devices'].items():
    if 'iOS-27-0' in runtime:
        choices = [d for d in devices if d.get('isAvailable') and d.get('name', '').startswith('iPhone')]
        choices.sort(key=lambda d: ('Pro Max' not in d['name'], d['name']))
        if choices:
            print(choices[0]['udid'])
            raise SystemExit(0)
raise SystemExit('No iOS 27.0 iPhone Simulator available; do not silently switch runtime.')
