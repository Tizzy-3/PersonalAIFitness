#!/usr/bin/env python3
"""Verify bundled media bytes and the explicit provenance manifest, without network access."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / 'Sources/PersonalFitness/Resources/ExerciseMedia'


def main():
    entries = json.loads((MEDIA / 'media-manifest.json').read_text(encoding='utf-8-sig'))
    if not isinstance(entries, list) or not entries:
        raise SystemExit('A nonempty per-media manifest is required.')
    ids, names = set(), {'media-manifest.json', 'NOTICE.md', 'wger-license-metadata.json'}
    for item in entries:
        if item['exerciseID'] in ids:
            raise SystemExit('Duplicate exercise media identifier.')
        ids.add(item['exerciseID'])
        if item['author'] != 'Goulart' or item['licenseName'] != 'CC-BY-SA 4':
            raise SystemExit('Media is outside the reviewed attribution scope.')
        if not item['sourceURL'].startswith('https://wger.de/media/exercise-video/') or not item['changes']:
            raise SystemExit('Missing source or transformation notice.')
        for field, digest_field in [('fileName', 'fileSHA256'), ('posterFileName', 'posterSHA256'), ('previewGIFFileName', 'previewGIFSHA256')]:
            name = item[field]
            if not re.fullmatch(r'[a-z0-9-]+\.(mp4|jpg|gif)', name) or name in names:
                raise SystemExit('Unsafe or duplicate media filename.')
            names.add(name)
            data = (MEDIA / name).read_bytes()
            if not data or hashlib.sha256(data).hexdigest() != item[digest_field]:
                raise SystemExit('Media checksum mismatch: ' + name)
            if name.endswith('.gif'):
                if data[:6] not in (b'GIF87a', b'GIF89a'):
                    raise SystemExit('Invalid GIF header.')
                width = int.from_bytes(data[6:8], 'little')
                height = int.from_bytes(data[8:10], 'little')
                if width > 160 or height > 160:
                    raise SystemExit('GIF dimensions exceed reviewed bounds.')
    if names != {p.name for p in MEDIA.iterdir() if p.is_file()}:
        raise SystemExit('Unlisted or missing file in bundled media directory.')
    print('MEDIA CHECKS PASSED: %d attributed clips, posters and GIFs; %d exact bundled files.' % (len(entries), len(names)))
    print('Checksums/paths/manifest verified. Correct personal technique is not established by this check.')


if __name__ == '__main__':
    main()
