#!/usr/bin/env python3
"""Exact file/provenance verification of the user-confirmed imported demonstration set."""
from pathlib import Path
import hashlib
import json
import re


def validate(media):
    manifest = json.loads((media / 'fed-media-manifest.json').read_text(encoding='utf-8'))
    entries = manifest['entries']
    if manifest.get('authorizationBasis') != 'userConfirmed' or len(entries) != 593:
        raise SystemExit('All 593 user-confirmed video variants must be explicitly inventoried.')
    names = {'fed-media-manifest.json', 'fed-NOTICE.md'}
    keys = set()
    source_ids = set()
    for item in entries:
        key = (item['sourceID'], item['variant'])
        if key in keys or item['variant'] not in ('male', 'female'):
            raise SystemExit('Duplicate or unknown demonstration variant.')
        keys.add(key)
        source_ids.add(item['sourceID'])
        for url_key in ['sourceURL', 'sourcePosterURL']:
            if not item[url_key].startswith('https://pub-585d42eb1aa64a67aedf483ec328d3fe.r2.dev/'):
                raise SystemExit('Unexpected source media host.')
        for hash_key in ['sourceSHA256', 'sourcePosterSHA256']:
            if not re.fullmatch('[a-f0-9]{64}', item[hash_key]):
                raise SystemExit('Source digest missing.')
        if not (0 < item['durationSeconds'] < 3600) or not (1 < item['frames'] <= 80):
            raise SystemExit('Invalid video/GIF duration or frames.')
        stem = 'fed-' + item['sourceID'] + '-' + item['variant']
        for name_key, hash_key, ext in [('fileName', 'fileSHA256', '.mp4'), ('posterFileName', 'posterSHA256', '.jpg'), ('previewGIFFileName', 'previewGIFSHA256', '.gif')]:
            name = item[name_key]
            if name != stem + ext or not re.fullmatch('[a-z0-9-]+\\.(mp4|jpg|gif)', name) or name in names:
                raise SystemExit('Unsafe or duplicate imported filename.')
            names.add(name)
            data = (media / name).read_bytes()
            if not data or hashlib.sha256(data).hexdigest() != item[hash_key]:
                raise SystemExit('Imported media checksum mismatch: ' + name)
            if ext == '.gif':
                if data[:6] not in (b'GIF87a', b'GIF89a') or max(int.from_bytes(data[6:8], 'little'), int.from_bytes(data[8:10], 'little')) > 160:
                    raise SystemExit('Imported preview must be a small real GIF.')
            elif ext == '.jpg' and not data.startswith(b'\xff\xd8'):
                raise SystemExit('Imported poster is not JPEG.')
            elif ext == '.mp4' and b'ftyp' not in data[:32]:
                raise SystemExit('Imported movie is not MP4.')
    if len(source_ids) != 317:
        raise SystemExit('Every one of the 317 source actions needs a demonstration.')
    print('IMPORTED MEDIA CHECKS PASSED: 317 source IDs, 593 video/GIF/poster variants, %d exact files; video usage user-confirmed.' % len(names))
    return names


if __name__ == '__main__':
    validate(Path(__file__).resolve().parents[1] / 'Sources/PersonalFitness/Resources/ExerciseMedia')
