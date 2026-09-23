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
    for source in sources:
        text = source.read_text()
        if re.search(r'\b(URLSession|WKWebView|AsyncImage|CKContainer|MKLocalSearch|CLGeocoder|MKMapSnapshotter)\b', text):
            errors.append(f'{source.name}: unapproved runtime network entry point')
        if 'import MapKit' in text and source.name != 'AppleMapsView.swift':
            errors.append(f'{source.name}: Maps must stay inside the consent-gated adapter')
        if re.search(r'https?://', text):
            errors.append(f'{source.name}: native runtime must not use remote URLs')
    maps = (native / 'Features/AppleMapsView.swift').read_text()
    if not re.search(r'if model\.mapsEnabled\s*\{\s*AppleMapSurface\(', maps):
        errors.append('MapKit surface is not behind the consent gate')
    if not re.search(r'if model\.mapsEnabled\s*\{\s*PlacePinSurface\(', maps):
        errors.append('Place editor map is not behind the consent gate')
    manifest = plistlib.loads((native / 'Resources/PrivacyInfo.xcprivacy').read_bytes())
    if manifest.get('NSPrivacyTracking') or manifest.get('NSPrivacyTrackingDomains') or manifest.get('NSPrivacyCollectedDataTypes'):
        errors.append('privacy manifest unexpectedly declares tracking or collection')
    for asset in json.loads((root / 'asset-provenance.json').read_text()):
        if hashlib.sha256((root / asset['path']).read_bytes()).hexdigest() != asset['sha256']:
            errors.append(f'asset differs from recorded source: {asset["path"]}')
    return errors


if __name__ == '__main__':
    problems = audit(Path(__file__).resolve().parents[1])
    if problems:
        print('\n'.join(problems), file=sys.stderr)
        sys.exit(1)
    print('Privacy/resource checks passed (static checks; device network validation is separate).')
