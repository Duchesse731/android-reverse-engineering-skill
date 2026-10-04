#!/usr/bin/env python3
"""Verify a downloaded GitHub release asset against its published SHA-256 digest."""
import argparse
import hashlib
import json
import re
import urllib.parse
import urllib.request
from pathlib import Path


def verify(url, path):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or parsed.netloc != 'github.com':
        raise ValueError('Only official HTTPS GitHub release URLs are supported')
    match = re.fullmatch(r'/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)', parsed.path)
    if not match:
        raise ValueError('Expected a GitHub release asset URL')
    owner, repo, tag, filename = map(urllib.parse.unquote, match.groups())
    api = f'https://api.github.com/repos/{owner}/{repo}/releases/tags/{urllib.parse.quote(tag, safe="")}'
    request = urllib.request.Request(api, headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'android-reverse-engineering-skill'})
    with urllib.request.urlopen(request, timeout=30) as response:
        release = json.load(response)
    asset = next((a for a in release.get('assets', []) if a.get('name') == filename), None)
    digest = asset.get('digest', '') if asset else ''
    if not re.fullmatch(r'sha256:[0-9a-fA-F]{64}', digest or ''):
        raise ValueError('Release has no published SHA-256 digest; use a package manager or verify and install manually')
    hasher = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
    if hasher.hexdigest() != digest[7:].lower():
        raise ValueError('SHA-256 mismatch; downloaded file must not be installed')
    print(f'Verified SHA-256: {filename}')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('url')
    p.add_argument('file', type=Path)
    args = p.parse_args()
    try:
        verify(args.url, args.file)
    except (OSError, ValueError, KeyError) as exc:
        p.exit(1, f'Verification failed: {exc}\n')


if __name__ == '__main__':
    main()
