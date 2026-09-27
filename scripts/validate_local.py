#!/usr/bin/env python3
"""Run Places checks locally before pushing: --simulator <QA simulator UUID>."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True, help='Dedicated iOS 26+ QA simulator UUID')
    parser.add_argument('--derived-data', type=Path, default=ROOT / 'build/local-tests')
    args = parser.parse_args()
    if os.environ.get('CI'):
        parser.error('Tests run locally. CI only checks privacy and builds the app.')
    commands = [
        ('Privacy checks', [sys.executable, 'scripts/check_privacy.py']),
        ('Workflow smoke tests', [sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts/tests']),
        ('Core tests', ['swift', 'test', '--package-path', 'packages/PlacesCore']),
        ('App and UI tests', ['xcodebuild', '-project', 'apps/ios/Places.xcodeproj', '-scheme', 'Places',
                             '-destination', f'platform=iOS Simulator,id={args.simulator}',
                             '-derivedDataPath', str(args.derived_data.expanduser().resolve()),
                             '-disableAutomaticPackageResolution', '-parallel-testing-enabled', 'NO',
                             '-collect-test-diagnostics', 'never', 'CODE_SIGNING_ALLOWED=NO',
                             'COMPILATION_CACHE_ENABLE_CACHING=YES', 'test']),
    ]
    started = time.monotonic()
    for label, command in commands:
        print(f'\n{label}…', flush=True)
        result = subprocess.run(command, cwd=ROOT)
        if result.returncode:
            return result.returncode
    print(f'\nAll local checks passed in {time.monotonic() - started:.1f}s.', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
