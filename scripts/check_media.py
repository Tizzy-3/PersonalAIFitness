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
    ids, names = set(), {'media-manifest.json', 'NOTICE.md', 'wger-license-metadata.json', 'wger-image-license-metadata.json', 'wger-video-license-metadata.json'}
    sources = {'wger.image.' + str(x['id']): x for x in json.loads((MEDIA / 'wger-image-license-metadata.json').read_text(encoding='utf-8'))}
    videos = {'wger.video.' + str(x['id']): x for x in json.loads((MEDIA / 'wger-video-license-metadata.json').read_text(encoding='utf-8'))['results']}
    static_count = 0
    active_count = 0
    disabled_count = 0
    # A superseded static source remains licensed and checksummed but cannot become active.
    retained = []
    for item in entries:
        replaced = item.get('replacedStaticSource')
        if replaced:
            if item['type'] != 'video' or replaced['type'] not in ('image', 'stillSequence') or replaced['exerciseID'] != item['exerciseID'] or not replaced.get('replacementReason') or replaced.get('disabledReason'):
                raise SystemExit('Invalid retained static replacement history.')
            retained.append(replaced)
    for item in entries + retained:
        is_retained = item in retained
        if item['exerciseID'] in ids and not is_retained:
            raise SystemExit('Duplicate exercise media identifier.')
        if not is_retained:
            ids.add(item['exerciseID'])
        if 'disabledReason' in item:
            reason = item['disabledReason']
            if not isinstance(reason, str) or not reason.strip() or len(reason) > 500:
                raise SystemExit('Disabled media requires a bounded review reason.')
            disabled_count += 1
        elif not is_retained:
            active_count += 1
        if item['type'] in ('image', 'stillSequence'):
            if not item.get('frames') or (item['type'] == 'stillSequence') != (len(item['frames']) > 1):
                raise SystemExit('Invalid static sequence mapping.')
            if item['fileName'] != item['posterFileName'] or item['fileName'] != item['frames'][0]['fileName']:
                raise SystemExit('Still poster mapping mismatch.')
            for frame in item['frames']:
                upstream = sources.get(frame['sourceObjectID'])
                if not upstream or upstream['license_author'] != 'Everkinetic' or upstream['license'] != 1 or frame['author'] != 'Everkinetic' or frame['licenseName'] != 'CC-BY-SA 3':
                    raise SystemExit('Static image outside reviewed attribution scope.')
                if frame['sourceURL'] != upstream['image'] or frame['licenseURL'] != 'https://creativecommons.org/licenses/by-sa/3.0/deed.en' or not frame['changes']:
                    raise SystemExit('Static image provenance mismatch.')
                name = frame['fileName']
                if not re.fullmatch(r'[a-z0-9-]+\.jpg', name) or name in names:
                    raise SystemExit('Unsafe or duplicate static image filename.')
                names.add(name)
                data = (MEDIA / name).read_bytes()
                if not data.startswith(b'\xff\xd8') or hashlib.sha256(data).hexdigest() != frame['fileSHA256']:
                    raise SystemExit('Static image checksum mismatch.')
                static_count += 1
            continue
        if item['author'] != 'Goulart' or item['licenseName'] != 'CC-BY-SA 4':
            raise SystemExit('Media is outside the reviewed attribution scope.')
        source = videos.get(item['sourceObjectID'])
        if not source or source['license_author'] != item['author'] or source['license'] != 2 or source['video'] != item['sourceURL'] or source['size'] != item['expectedSourceBytes']:
            raise SystemExit('Video outside individually reviewed source metadata.')
        if item['licenseURL'] != 'https://creativecommons.org/licenses/by-sa/4.0/deed.en' or not re.fullmatch(r'[a-f0-9]{64}', item['sourceSHA256']):
            raise SystemExit('Missing video license or source digest.')
        if not (0 < item['previewGIFDurationSeconds'] <= 6) or item['previewGIFStartSeconds'] < 0 or item['previewGIFStartSeconds'] + item['previewGIFDurationSeconds'] > item['durationSeconds'] + 0.05:
            raise SystemExit('GIF must be a bounded continuous segment of the source video.')
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
    print('MEDIA CHECKS PASSED: %d active movement mappings / %d disabled retained sources / %d static frames; %d exact bundled files.' % (active_count, disabled_count, static_count, len(names)))
    print('Checksums/paths/manifest verified. Correct personal technique is not established by this check.')


if __name__ == '__main__':
    main()
