#!/usr/bin/env python3
"""Fast runtime-resource/privacy checks. No network calls or external packages."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlparse
import hashlib
import json
import plistlib
import re
import sys


def check_resource(url, parent, website):
    parsed = urlparse(url)
    if parsed.scheme or parsed.netloc or url.startswith('//'):
        return [f'remote or embedded resource: {url}']
    path = (website / parsed.path.lstrip('/')) if url.startswith('/') else parent / parsed.path
    path = path.resolve()
    if not path.is_relative_to(website.resolve()) or not path.is_file():
        return [f'missing or out-of-root resource: {url}']
    return []


class ResourceParser(HTMLParser):
    def __init__(self, parent, website):
        super().__init__()
        self.parent, self.website, self.errors = parent, website, []
        self.has_csp = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ('script', 'iframe', 'object', 'embed'):
            self.errors.append(f'active/embedded content is not used by this static site: {tag}')
        if tag == 'meta' and attrs.get('http-equiv', '').lower() == 'content-security-policy':
            self.has_csp = "connect-src 'none'" in attrs.get('content', '')
        resources = []
        for key in ('src', 'poster'):
            if key in attrs:
                resources.append(attrs[key])
        if 'srcset' in attrs:
            resources += [entry.strip().split()[0] for entry in attrs['srcset'].split(',') if entry.strip()]
        if tag == 'link':
            if any(x in attrs.get('rel', '') for x in ('preconnect', 'dns-prefetch', 'prefetch')):
                self.errors.append('no speculative connections or prefetch')
            if 'href' in attrs:
                resources.append(attrs['href'])
        for url in resources:
            self.errors += check_resource(url, self.parent, self.website)
        if any(key.startswith('on') for key in attrs):
            self.errors.append('inline event handlers are not used by this static site')


def check_css(css, parent, website):
    errors = []
    if re.search(r'@import\b', css, re.I):
        errors.append('CSS imports are not allowed; bundle styles locally')
    for url in re.findall(r'url\(\s*[\'\"]?([^\)\'\"]+)', css, re.I):
        errors += check_resource(url.strip(), parent, website)
    return errors


def has_remote_url(text, gpx_export=False):
    if gpx_export:
        # The GPX XML namespace is a format identifier, never a network request.
        text = text.replace('xmlns="http://www.topografix.com/GPX/1/1"', '')
    return bool(re.search(r'https?://', text))


def check_companion_cloud(text):
    errors = []
    for guard in ['guard consented else', 'container.privateCloudDatabase', 'CompanionCipher.seal(',
                  'CompanionCipher.open(', 'try batch.validate(', 'try await checkAccount(account)']:
        if guard not in text:
            errors.append('Encrypted companion inbox missing safeguard: ' + guard)
    if 'publicCloudDatabase' in text or 'sharedCloudDatabase' in text:
        errors.append('Companion evidence must use the private database')
    fields = set(re.findall(r'record\["([^"]+)"\]\s*=', text))
    if fields != {'payload', 'keyID'}:
        errors.append('Cloud records may contain only ciphertext and an opaque key identifier')
    return errors


def audit(root):
    errors = []
    website = root / 'apps/website'
    for page in website.rglob('*.html'):
        parser = ResourceParser(page.parent, website)
        parser.feed(page.read_text())
        errors += [f'{page.name}: {error}' for error in parser.errors]
        if not parser.has_csp:
            errors.append(f'{page.name}: missing connection-blocking CSP')
    for css in website.rglob('*.css'):
        errors += check_css(css.read_text(), css.parent, website)
    native = root / 'apps/ios/Places'
    sources = list(native.rglob('*.swift')) + list((root / 'packages/PlacesCore/Sources').rglob('*.swift'))
    for path in ['apps/macos', 'apps/watch', 'apps/shared', 'packages/PlacesCompanion/Sources', 'packages/PlacesRouting/Sources']:
        sources += list((root / path).rglob('*.swift'))
    cloud = root / 'packages/PlacesCompanion/Sources/PlacesCompanion/CloudInbox.swift'
    for source in sources:
        text = source.read_text()
        if re.search(r'\b(WKWebView|AsyncImage|MKLocalSearch|CLGeocoder|MKMapSnapshotter)\b', text):
            errors.append(f'{source.name}: unapproved runtime network entry point')
        if re.search(r'\bCKContainer\b', text) and source != cloud:
            errors.append(f'{source.name}: CloudKit must stay inside the encrypted, consent-gated adapter')
        if re.search(r'\bURLSession\b', text) and source != native / 'App/MapDownloads.swift':
            errors.append(f'{source.name}: downloads must stay in the approved map pack adapter')
        if ('import MapKit' in text or 'MKReverseGeocodingRequest(' in text) and source.name != 'AppleMapsView.swift':
            errors.append(f'{source.name}: Maps must stay inside the consent-gated adapter')
        if has_remote_url(text, source == root / 'packages/PlacesCore/Sources/PlacesCore/GPXExport.swift'):
            errors.append(f'{source.name}: native runtime must not use remote URLs')
    errors += check_companion_cloud(cloud.read_text())
    routing = root / 'packages/PlacesRouting/Sources'
    if routing.exists():
        bridge = (routing / 'PlacesRoutingNative/PlacesRoutingNative.mm').read_text()
        if 'make_unique<ValhallaActor>(configPath.UTF8String, nullptr)' not in bridge:
            errors.append('Offline routing must provide no HTTP client')
        if 'logging::Configure({{"type", ""}})' not in bridge:
            errors.append('Native routing logs must be disabled before graph access')
        if re.search(r'\b(NSURLSession|URLSession|NSURLRequest|NSLog|printf)\b', bridge):
            errors.append('Native routing bridge must not add network/logging entry points')
        config = json.loads((routing / 'PlacesRouting/Resources/config.json').read_text())
        if re.search(r'https?://|"tile_url"|"httpd"|"statsd"', json.dumps(config)):
            errors.append('Offline routing configuration must not contain remote resources or telemetry')
    maps = (native / 'Features/AppleMapsView.swift').read_text()
    if not re.search(r'if model\.mapsEnabled\s*\{\s*AppleMapSurface\(', maps):
        errors.append('MapKit surface is not behind the consent gate')
    if not re.search(r'if model\.mapsEnabled\s*\{\s*PlacePinSurface\(', maps):
        errors.append('Place editor map is not behind the consent gate')
    if not re.search(r'guard enabled, coordinate.isValid, !Task.isCancelled else \{ return nil \}', maps):
        errors.append('City lookup must check live opt-in before constructing a request')
    if 'request?.cancel()' not in maps or 'generation == expected' not in maps:
        errors.append('City lookup must cancel and discard responses after consent revocation')
    errors += check_map_resources(native / 'Resources/OfflineMaps')
    downloads = (native / 'App/MapDownloads.swift').read_text()
    for safeguard in ['pack.isValid', 'packs.contains(pack)', 'MapPackFiles.validate(', 'MapDownloadPolicy.canStart(',
                      'configuration.allowsCellularAccess = approved', 'configuration.allowsConstrainedNetworkAccess = approved']:
        if safeguard not in downloads:
            errors.append(f'Map downloads missing safeguard: {safeguard}')
    offline = (native / 'Features/OfflineMapView.swift').read_text()
    if 'configuration.protocolClasses = [OfflineMapNetworkBlocker.self]' not in offline or 'URLError(.notConnectedToInternet)' not in offline:
        errors.append('Offline renderer must block remote requests')
    manifest = plistlib.loads((native / 'Resources/PrivacyInfo.xcprivacy').read_bytes())
    if manifest.get('NSPrivacyTracking') or manifest.get('NSPrivacyTrackingDomains') or manifest.get('NSPrivacyCollectedDataTypes'):
        errors.append('privacy manifest unexpectedly declares tracking or collection')
    for asset in json.loads((root / 'asset-provenance.json').read_text()):
        if hashlib.sha256((root / asset['path']).read_bytes()).hexdigest() != asset['sha256']:
            errors.append(f'asset differs from recorded source: {asset["path"]}')
    return errors


def check_map_manifest(packs):
    errors = []
    if len(packs) != 3 or {p.get('id') for p in packs} != {'world', 'netherlands', 'greece'}:
        errors.append('Map pack manifest must contain exactly the three supported packs')
    for pack in packs:
        version = pack.get('version', '')
        expected = f'https://places-app.b-cdn.net/maps/bootstrap/{version}/{pack.get("id")}.pmtiles'
        if not re.fullmatch(r'[0-9.]+', version) or pack.get('url') != expected:
            errors.append('Map pack URL must be an immutable Places release asset with no query or fragment')
        if not re.fullmatch('[0-9a-f]{64}', pack.get('sha256', '')):
            errors.append('Map pack must have a SHA-256 checksum')
        size = pack.get('bytes', 0)
        if not isinstance(size, int) or size <= 127 or (pack.get('id') == 'world' and size > 100_000_000):
            errors.append('Map pack needs a measured size within the World ceiling')
        if (pack.get('minZoom'), pack.get('maxZoom')) != ((0, 6) if pack.get('id') == 'world' else (7, 12)):
            errors.append('Unexpected map pack zoom coverage')
    return errors


def check_map_resources(directory):
    errors = check_map_manifest(json.loads((directory / 'packs.json').read_text()))
    for name in ['style-light.json', 'style-dark.json']:
        style = json.loads((directory / name).read_text())
        # Runtime injects only local glyph/source URLs into these templates.
        if style.get('sources') or style.get('glyphs') or style.get('sprite') or re.search(r'https?://', json.dumps(style)):
            errors.append(f'{name}: map styles must not contain external resources')
    for first in range(0, 65536, 256):
        if not (directory / 'fonts/Noto Sans Regular' / f'{first}-{first + 255}.pbf').is_file():
            errors.append('Missing bundled map font range')
            break
    # Only the three measured Amsterdam picker samples may be bundled.
    import hashlib
    preview = directory / 'Previews'
    manifest = json.loads((preview / 'manifest.json').read_text())
    expected = {preview / ('amsterdam-' + level + '.pmtiles') for level in ('tiny', 'normal', 'extensive')}
    if set(directory.rglob('*.pmtiles')) != expected:
        errors.append('Only Amsterdam picker previews may be bundled')
    if sum(p.stat().st_size for p in expected if p.exists()) > 5_000_000:
        errors.append('Amsterdam previews exceed the bundle budget')
    for pack in manifest['variants']:
        path = preview / ('amsterdam-' + pack['detail'] + '.pmtiles')
        if path not in expected or not path.exists() or path.stat().st_size != pack['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest() != pack['sha256']:
            errors.append('Amsterdam preview does not match its measured manifest')
    return errors


if __name__ == '__main__':
    problems = audit(Path(__file__).resolve().parents[1])
    if problems:
        print('\n'.join(problems), file=sys.stderr)
        sys.exit(1)
    print('Privacy/resource checks passed (static checks; device network validation is separate).')
