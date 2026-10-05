#!/usr/bin/env python3
"""Fast internal beta: python3 scripts/testflight.py --team TEAM_ID.

Uses the signed-in Xcode account locally. For unattended uploads, set ASC_KEY_PATH,
ASC_KEY_ID and ASC_ISSUER_ID. Keep the private key outside this repository.
Create an internal TestFlight group with automatic distribution once in App Store
Connect. Apple processing and installation happen after this uploader finishes.
Use --archive-only to benchmark without uploading; --dry-run prints the steps.
Use --platform macos for the native menu bar companion in the same TestFlight app.
Run scripts/validate_local.py before pushing. CI uses --skip-tests because the
test suites run locally; archive and upload still validate the release build.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def validate_distribution_profile(profile, team, bundle, now=None, platform='ios'):
    entitlements = profile.get('Entitlements', {})
    identifier = 'com.apple.application-identifier' if platform == 'macos' else 'application-identifier'
    if profile.get('TeamIdentifier') != [team] or entitlements.get(identifier) != team + '.' + bundle:
        raise ValueError('Signing profile belongs to a different team or app.')
    if (entitlements.get('get-task-allow') or entitlements.get('com.apple.security.get-task-allow')
            or profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices')
            or (platform == 'ios' and not entitlements.get('beta-reports-active'))):
        raise ValueError('An App Store distribution profile is required.')
    if profile['ExpirationDate'].replace(tzinfo=timezone.utc) <= (now or datetime.now(timezone.utc)):
        raise ValueError('Signing profile has expired.')
    if platform == 'macos':
        if 'OSX' not in profile.get('Platform', []):
            raise ValueError('A Mac App Store distribution profile is required.')
        if ('iCloud.com.adriaan.places' not in entitlements.get('com.apple.developer.icloud-container-identifiers', [])
                or 'Production' not in entitlements.get('com.apple.developer.icloud-container-environment', [])):
            raise ValueError('Regenerate the Mac App Store profile with the Places CloudKit container enabled.')
    elif bundle == 'com.adriaan.places':
        if 'iCloud.com.adriaan.places' not in entitlements.get('com.apple.developer.icloud-container-identifiers', []):
            raise ValueError('Regenerate the iPhone profile with the Places CloudKit container enabled.')
        if entitlements.get('aps-environment') != 'production':
            raise ValueError('Regenerate the iPhone profile with Push Notifications enabled.')
    elif bundle.startswith('com.adriaan.places.watch'):
        if 'group.com.adriaan.places.watch' not in entitlements.get('com.apple.security.application-groups', []):
            raise ValueError('Regenerate the Watch profile with the Places Watch app group enabled.')
    value = profile['UUID']
    uuid.UUID(value)
    return value


def build_number(now=None):
    now = now or datetime.now(timezone.utc)
    # Apple's three numeric components: at most 4, 2 and 2 digits.
    days = (now.date() - datetime(2020, 1, 1).date()).days + 1
    return f'{days}.{now.hour}.{now.minute}'


def authentication(env):
    values = [env.get(k) for k in ('ASC_KEY_PATH', 'ASC_KEY_ID', 'ASC_ISSUER_ID')]
    if not any(values):
        return []  # Xcode's existing Apple account / cloud signing session.
    if not all(values):
        raise ValueError('Set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID together.')
    path = Path(values[0]).expanduser().resolve()
    if not path.is_file():
        raise ValueError('The App Store Connect private key file is missing.')
    if path.is_relative_to(ROOT):
        raise ValueError('Keep the App Store Connect private key outside the repository.')
    return ['-authenticationKeyPath', str(path), '-authenticationKeyID', values[1],
            '-authenticationKeyIssuerID', values[2]]


def export_options(team, profile=None, watch_profile=None, complication_profile=None, platform='ios'):
    options = {'method': 'app-store-connect', 'destination': 'upload',
            'signingStyle': 'automatic', 'teamID': team,
            'testFlightInternalTestingOnly': True,
            'manageAppVersionAndBuildNumber': True, 'uploadSymbols': True}
    if profile:
        options.update(signingStyle='manual', signingCertificate='Apple Distribution',
                       provisioningProfiles={'com.adriaan.places': profile})
        if platform == 'macos':
            options['installerSigningCertificate'] = 'Mac Installer Distribution'
        elif watch_profile:
            options['provisioningProfiles']['com.adriaan.places.watch'] = watch_profile
        if platform == 'ios' and complication_profile:
            options['provisioningProfiles']['com.adriaan.places.watch.widgets'] = complication_profile
    return options


def clean_revision():
    dirty = subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True)
    if dirty.strip():
        raise ValueError('Commit the source changes before uploading. --archive-only can validate work in progress.')
    return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()


def compilation_cache_summary(log):
    # Xcode reports all cacheable tasks once, including Swift and Clang. Never
    # publish archive/signing command lines or double-count individual remarks.
    metrics = re.findall(r'note: (\d+) hits / (\d+) cacheable tasks', log)
    if not metrics:
        return None
    hits, tasks = map(int, metrics[-1])
    return {'hits': hits, 'misses': tasks - hits}


def execute(args, env=os.environ):
    if not re.fullmatch(r'[A-Z0-9]{10}', args.team or ''):
        raise ValueError('Provide --team or PLACES_TEAM_ID (the 10-character Apple Developer team ID).')
    if not re.fullmatch(r'[1-9][0-9]{0,3}\.[0-9]{1,2}\.[0-9]{1,2}', args.build_number):
        raise ValueError('Use a build number such as 2460.10.25 (up to 4.2.2 digits).')
    auth = authentication(env)
    platform = getattr(args, 'platform', 'ios')
    profile_name = 'PLACES_MAC_PROFILE_UUID' if platform == 'macos' else 'PLACES_PROFILE_UUID'
    profile = env.get(profile_name)
    watch_profile = env.get('PLACES_WATCH_PROFILE_UUID')
    complication_profile = env.get('PLACES_COMPLICATION_PROFILE_UUID')
    if profile and not re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}', profile):
        raise ValueError(profile_name + ' must identify the installed Places distribution profile.')
    for name, value in [('PLACES_WATCH_PROFILE_UUID', watch_profile), ('PLACES_COMPLICATION_PROFILE_UUID', complication_profile)]:
        if value and not re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}', value):
            raise ValueError(name + ' must identify an installed distribution profile.')
    if platform == 'ios' and profile and not (watch_profile and complication_profile):
        raise ValueError('Manual signing also requires PLACES_WATCH_PROFILE_UUID and PLACES_COMPLICATION_PROFILE_UUID.')
    # Only the Places Release target consumes these custom settings. Global
    # signing overrides also reach Swift package resource bundles, which cannot
    # accept an app provisioning profile.
    signing = ([f'{profile_name}={profile}', 'PLACES_CODE_SIGN_STYLE=Manual',
                'PLACES_CODE_SIGN_IDENTITY=Apple Distribution'] if profile else [])
    if profile and platform == 'ios':
        signing += [f'PLACES_WATCH_PROFILE_UUID={watch_profile}', f'PLACES_COMPLICATION_PROFILE_UUID={complication_profile}']
    scheme = 'PlacesMac' if platform == 'macos' else 'Places'
    work = args.work_dir.expanduser().resolve()
    work.mkdir(parents=True, exist_ok=True)
    # Prevent two local releases from changing the same archive or build cache.
    with (work / 'release.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another TestFlight release is using this build directory.') from None
        revision = None if args.archive_only or args.dry_run else clean_revision()
        archive = work / f'{scheme}.xcarchive'
        options = work / 'ExportOptions.plist'
        options.write_bytes(plistlib.dumps(export_options(args.team, profile, watch_profile, complication_profile, platform)))
        phases = [
            ('Privacy checks', [sys.executable, 'scripts/check_privacy.py']),
        ]
        if not args.skip_tests:
            phases.extend([
                ('Workflow smoke tests', [sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts/tests']),
                ('Core tests', ['swift', 'test', '--package-path', 'packages/PlacesCore']),
            ])
        phases.extend([
            ('Archive', ['xcodebuild', '-project', 'apps/ios/Places.xcodeproj', '-scheme', scheme,
                         '-configuration', 'Release', '-destination', 'generic/platform=macOS' if platform == 'macos' else 'generic/platform=iOS',
                         '-derivedDataPath', str(work / 'DerivedData'),
                         '-clonedSourcePackagesDirPath', str(work / 'SourcePackages'),
                         '-disableAutomaticPackageResolution', '-archivePath', str(archive),
                         'COMPILATION_CACHE_ENABLE_CACHING=YES',
                         'COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES',
                         f'COMPILATION_CACHE_CAS_PATH={work / "CompilationCache.noindex"}',
                         f'DEVELOPMENT_TEAM={args.team}', f'CURRENT_PROJECT_VERSION={args.build_number}',
                         *signing, '-allowProvisioningUpdates', *auth, 'archive']),
        ])
        if not args.archive_only:
            phases.append(('Upload', ['xcodebuild', '-exportArchive', '-archivePath', str(archive),
                                     '-exportPath', str(work / 'Export'), '-exportOptionsPlist', str(options),
                                     '-allowProvisioningUpdates', *auth]))
        timings = {'revision': revision, 'platform': platform, 'archiveBuildNumber': args.build_number, 'phases': {}}
        started = time.monotonic()
        try:
            for label, command in phases:
                if args.dry_run:
                    print(label + ': ' + ' '.join(command), flush=True)
                    continue
                if label == 'Upload' and clean_revision() != revision:
                    raise ValueError('The source changed during the build. Upload cancelled; run again from the intended commit.')
                phase_start = time.monotonic()
                log = work / (label.lower().replace(' ', '-') + '.log')
                print(f'{label}… (log: {log})', flush=True)
                with log.open('w') as output:
                    result = subprocess.run(command, cwd=ROOT, env=dict(env), stdout=output, stderr=subprocess.STDOUT)
                timings['phases'][label] = round(time.monotonic() - phase_start, 1)
                if result.returncode:
                    # Surface Xcode's actionable errors without publishing signing logs.
                    errors = [line.strip() for line in log.read_text(errors='replace').splitlines()
                              if line.startswith('error: ') or ' error: ' in line]
                    for error in errors[-8:]:
                        print(error[:800], file=sys.stderr, flush=True)
                    raise RuntimeError(f'{label} failed. See {log}. No later release steps were run.')
                print(f'{label}: {timings["phases"][label]}s', flush=True)
                if label == 'Archive':
                    cache = compilation_cache_summary(log.read_text(errors='replace'))
                    timings['compilationCache'] = cache
                    if cache is not None:
                        print(f'Compiler cache: {cache["hits"]} hits, {cache["misses"]} misses.', flush=True)
                    else:
                        print('Compiler cache metrics unavailable in this Xcode log.', flush=True)
            if not args.dry_run:
                print('Archive ready; nothing uploaded.' if args.archive_only else
                      'Upload accepted. Apple must finish processing before TestFlight can install it.\n'
                      'The internal group must have automatic distribution enabled.', flush=True)
        finally:
            timings['totalSeconds'] = round(time.monotonic() - started, 1)
            (work / 'timings.json').write_text(json.dumps(timings, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--team', default=os.environ.get('PLACES_TEAM_ID'))
    parser.add_argument('--platform', choices=('ios', 'macos'), default='ios')
    parser.add_argument('--archive-only', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--skip-tests', action='store_true',
                        help='CI only: tests have already been run locally before pushing.')
    parser.add_argument('--build-number', default=build_number())
    parser.add_argument('--work-dir', type=Path)
    args = parser.parse_args()
    if args.work_dir is None:
        args.work_dir = ROOT / ('build/testflight-macos' if args.platform == 'macos' else 'build/testflight')
    try:
        execute(args)
    except (ValueError, RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
