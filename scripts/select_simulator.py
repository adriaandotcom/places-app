#!/usr/bin/env python3
import json
import subprocess
import sys

devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
candidates = [(int(runtime.split('iOS-')[-1].split('-')[0]), device['udid'])
              for runtime, values in devices.items() if 'iOS-' in runtime
              for device in values if device['name'].startswith('iPhone') and device['isAvailable']
              and int(runtime.split('iOS-')[-1].split('-')[0]) >= 26]
if not candidates:
    sys.exit('An iOS 26 or newer iPhone simulator runtime is required.')
print(sorted(candidates, reverse=True)[0][1])
