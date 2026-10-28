#!/usr/bin/env python3
"""Rebuild reviewed wger video derivatives; explicit mapping, never fuzzy matching.

Sources are cached outside the application bundle. Each reviewed source is Goulart,
CC BY-SA 4.0; the API snapshot preserves source IDs, UUIDs, size and attribution.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / 'Sources/PersonalFitness/Resources/ExerciseMedia'
CHANGES = ('Re-encoded to 480px H.264 MP4 without audio. Poster extracted from the midpoint. '
           'A centered continuous segment up to 6 seconds is converted to a 160px/6fps '
           'looping GIF preview. All derivatives retain CC BY-SA 4.0.')


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ffmpeg(*args):
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *map(str, args)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    mapping = read(ROOT / 'Data/exercise-motion-media.json')
    sources = {v['id']: v for v in read(MEDIA / 'wger-video-license-metadata.json')['results']}
    old = {v['exerciseID']: v for v in read(MEDIA / 'media-manifest.json')}

    def build(row):
        v = sources[row['videoID']]
        assert v['exercise'] == row['upstreamExerciseID']
        assert v['license_author'] == 'Goulart' and v['license'] == 2
        assert v['video'].startswith('https://wger.de/media/exercise-video/')
        previous = old.get(row['exerciseID'])
        assert not previous or not previous.get('disabledReason'), 'Disabled bindings require separate review'
        source = args.cache / ('source-%d.mov' % v['id'])
        if not source.exists():
            with urllib.request.urlopen(v['video'], timeout=180) as response, source.open('wb') as output:
                while True:
                    data = response.read(1024 * 1024)
                    if not data:
                        break
                    output.write(data)
        assert source.stat().st_size == v['size'], 'Unexpected upstream source size'
        slug = row['exerciseID'][len('builtin.'):]
        clip, poster, gif = [MEDIA / (slug + suffix) for suffix in ('.mp4', '-poster.jpg', '.gif')]
        duration = float(v['duration'])
        start, length = max(0, (duration - 6) / 2), min(6, duration)
        ffmpeg('-i', source, '-map', '0:v:0', '-an', '-vf', 'scale=480:480:force_original_aspect_ratio=decrease:force_divisible_by=2',
               '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '25', '-preset', 'fast', '-threads', '2', '-movflags', '+faststart', clip)
        ffmpeg('-ss', duration / 2, '-i', source, '-frames:v', '1', '-vf', 'scale=480:480:force_original_aspect_ratio=decrease', '-threads', '1', poster)
        ffmpeg('-ss', start, '-t', length, '-i', source, '-filter_complex',
               'fps=6,scale=160:160:force_original_aspect_ratio=decrease:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer',
               '-loop', '0', '-threads', '1', gif)
        item = dict(exerciseID=row['exerciseID'], type='video', sourceURL=v['video'], sourceObjectID='wger.video.%d' % v['id'],
                    sourceTitle=row['sourceTitle'], author='Goulart', licenseName='CC-BY-SA 4',
                    licenseURL='https://creativecommons.org/licenses/by-sa/4.0/deed.en',
                    exerciseURL='https://wger.de/api/v2/exerciseinfo/%d/' % v['exercise'], fileName=clip.name,
                    posterFileName=poster.name, previewGIFFileName=gif.name, expectedSourceBytes=v['size'],
                    sourceSHA256=digest(source), fileSHA256=digest(clip), posterSHA256=digest(poster),
                    previewGIFSHA256=digest(gif), fileBytes=clip.stat().st_size, durationSeconds=duration,
                    previewGIFStartSeconds=start, previewGIFDurationSeconds=length, changes=CHANGES,
                    verifiedDate='2026-10-28', mappingReview=row['mappingReview'])
        if previous and previous['type'] in ('image', 'stillSequence'):
            item['replacedStaticSource'] = previous
            item['replacedStaticSource']['replacementReason'] = 'Replaced at runtime by a reviewed continuous video; source stills retained for provenance.'
        elif previous and previous.get('replacedStaticSource'):
            item['replacedStaticSource'] = previous['replacedStaticSource']
        print('Built ' + row['exerciseID'], flush=True)
        return item

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        built = list(pool.map(build, mapping))
    for item in built:
        old[item['exerciseID']] = item
    (MEDIA / 'media-manifest.json').write_text(json.dumps(list(old.values()), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    lines = ['import Foundation', '', '/// Explicitly reviewed continuous videos. Generated by scripts/import_motion_media.py.', 'enum MotionMediaCatalog {', '    static let entries: [String: ExerciseMediaDescriptor] = [']
    quote = lambda s: json.dumps(s, ensure_ascii=False)
    for item in built:
        fields = ['kind: .video'] + [k + ': ' + quote(item[k]) for k in ['fileName', 'posterFileName', 'previewGIFFileName', 'sourceURL', 'author', 'licenseName', 'licenseURL', 'changes']]
        fields.append('durationSeconds: ' + str(item['durationSeconds']))
        lines.append('        ' + quote(item['exerciseID']) + ': ExerciseMediaDescriptor(' + ', '.join(fields) + '),')
    lines += ['    ]', '}', '']
    (ROOT / 'Packages/FitnessCore/Sources/FitnessCore/MotionMediaCatalog.swift').write_text('\n'.join(lines), encoding='utf-8')


if __name__ == '__main__':
    main()
