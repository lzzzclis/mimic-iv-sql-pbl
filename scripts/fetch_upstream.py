#!/usr/bin/env python3
"""Download the pinned, public paper-code archive; never execute it."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile


def verify(path, source):
    blob = path.read_bytes()
    for algorithm in ('md5', 'sha256'):
        actual = hashlib.new(algorithm, blob).hexdigest()
        if actual != source[algorithm]:
            raise ValueError(f'{algorithm} mismatch for archive')
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('ZIP integrity check failed')
    print('Archive MD5, SHA-256 and ZIP integrity checks passed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-only', type=Path, metavar='ZIP')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = json.loads((root / 'sources.json').read_text())['archive']
    if args.verify_only is not None:
        verify(args.verify_only, source)
        return
    target = root / 'vendor' / 'ObservedThresholdsForIMV-v1.0.1.zip'
    target.parent.mkdir(exist_ok=True)
    if target.exists():
        verify(target, source)
        return
    # Exclusive creation avoids overwriting local assets. Download is public.
    request = urllib.request.Request(source['url'], headers={'User-Agent': 'mimic-sql-pbl/0.1'})
    with urllib.request.urlopen(request, timeout=60) as response:
        blob = response.read(25 * 1024 * 1024 + 1)
    if len(blob) > 25 * 1024 * 1024:
        raise ValueError('Unexpected archive size')
    for algorithm in ('md5', 'sha256'):
        if hashlib.new(algorithm, blob).hexdigest() != source[algorithm]:
            raise ValueError(f'{algorithm} mismatch; archive was not saved')
    with target.open('xb') as output:
        output.write(blob)
    verify(target, source)


if __name__ == '__main__':
    main()
