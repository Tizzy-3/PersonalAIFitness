#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Import every supplied free-exercise-db demo variant into an offline bundle.

Video acceptance was explicitly confirmed by the personal App owner on 2026-10-28.
This is not an independent verification of the upstream seller's video rights.
The MIT notice applies to upstream code/metadata; media provenance stays explicit.
Downloads and work files remain in ignored output; the final manifest is complete
only if every input video/poster has downloaded, decoded, and passed output checks.
"""
import argparse
import concurrent.futures
import hashlib
import json
import math
import re
import subprocess
import time
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, build_opener, ProxyHandler

ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / 'Sources/PersonalFitness/Resources/ExerciseMedia'
HOST = 'pub-585d42eb1aa64a67aedf483ec328d3fe.r2.dev'
REPOSITORY = 'https://github.com/luisaraujoc/free-exercise-db-api'
CHANGES = ('Full source video re-encoded to <=480px H.264/yuv420p MP4 without audio. '
           'Matching upstream poster re-encoded to <=480px JPEG. A centered continuous '
           'segment up to 6 seconds converted to a <=160px/6fps looping GIF. '
           'Video use confirmed by personal App owner; upstream seller rights not independently verified.')


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def safe_stem(source_id, variant):
    if not re.fullmatch(r'[a-z0-9-]+', source_id) or variant not in ('male', 'female'):
        raise ValueError('Unexpected source ID or demo variant')
    return 'fed-' + source_id + '-' + variant


def validate_url(value, kind, variant):
    url = urlparse(value)
    prefix = '/exercise-videos/' if kind == 'video' else '/exercise-posters/'
    if url.scheme != 'https' or url.hostname != HOST or not url.path.startswith(prefix + variant + '/') or url.query or url.fragment:
        raise ValueError('Unexpected upstream media URL')


def download(url, path):
    if path.exists() and path.stat().st_size > 0:
        return path.stat().st_size
    temporary = path.with_suffix(path.suffix + '.part')
    for attempt in range(3):
        try:
            opener = build_opener(ProxyHandler({}))
            with opener.open(Request(url, headers={'User-Agent': 'PersonalFitnessMediaImport/0.6.2'}), timeout=45) as response:
                if urlparse(response.geturl()).hostname != HOST:
                    raise ValueError('Upstream redirected outside reviewed media host')
                expected = int(response.headers.get('Content-Length', '0'))
                count = 0
                with temporary.open('wb') as output:
                    while True:
                        block = response.read(128 * 1024)
                        if not block:
                            break
                        count += len(block)
                        if count > 32 * 1024 * 1024:
                            raise ValueError('Source exceeds bounded per-file import size')
                        output.write(block)
                if not count or (expected and count != expected):
                    raise ValueError('Incomplete source response')
                temporary.replace(path)
                return count
        except Exception:
            if temporary.exists():
                temporary.unlink()
            if attempt == 2:
                raise
            time.sleep(attempt + 1)


def probe(path, frames=False):
    args = ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
            'stream=codec_name,width,height,nb_read_frames:format=duration', '-of', 'json']
    if frames:
        args.append('-count_frames')
    result = json.loads(subprocess.check_output(args + [str(path)], stderr=subprocess.STDOUT))
    if len(result.get('streams', [])) != 1:
        raise ValueError('Missing decodable video/image track: ' + path.name)
    return result['streams'][0], float(result.get('format', {}).get('duration', 0))


def ffmpeg(*args):
    result = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *map(str, args)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr.decode('utf-8', errors='replace')[-1200:])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--cache', type=Path, default=ROOT / 'output/fed-source-cache')
    parser.add_argument('--workers', type=int, default=8)
    parser.add_argument('--limit', type=int, help='Diagnostic subset only; never writes the complete manifest')
    args = parser.parse_args()
    rows = json.loads(args.dataset.read_text(encoding='utf-8-sig'))
    if len(rows) != 317 or len({row['id'] for row in rows}) != 317:
        raise ValueError('Dataset does not match reviewed 317 unique source identities')
    tasks = []
    for row in rows:
        for variant, video_url in row['videos'].items():
            stem = safe_stem(row['id'], variant)
            poster_url = row['thumbnails'].get(variant)
            validate_url(video_url, 'video', variant)
            validate_url(poster_url, 'poster', variant)
            tasks.append((row, variant, video_url, poster_url, stem))
    if len(tasks) != 593 or len({task[4] for task in tasks}) != 593:
        raise ValueError('Dataset does not match all 593 unique media variants')
    complete = args.limit is None
    tasks = tasks if complete else tasks[:args.limit]
    args.cache.mkdir(parents=True, exist_ok=True)
    MEDIA.mkdir(parents=True, exist_ok=True)
    results, failures = [], []

    def build(task):
        row, variant, video_url, poster_url, stem = task
        source, source_poster = args.cache / (stem + '.source.mp4'), args.cache / (stem + '.source.jpg')
        proof = args.cache / (stem + '.verified.json')
        clip, poster, gif = [MEDIA / (stem + ext) for ext in ('.mp4', '.jpg', '.gif')]
        if proof.exists():
            previous = json.loads(proof.read_text(encoding='utf-8'))
            if previous.get('sourceURL') == video_url and previous.get('sourcePosterURL') == poster_url and all(
                    path.exists() and digest(path) == previous[field]
                    for path, field in [(clip, 'fileSHA256'), (poster, 'posterSHA256'), (gif, 'previewGIFSHA256')]):
                return previous
        source_bytes, poster_bytes = download(video_url, source), download(poster_url, source_poster)
        source_stream, duration = probe(source)
        if not math.isfinite(duration) or not 0 < duration <= 300:
            raise ValueError('Unexpected source duration')
        probe(source_poster)
        start, length = max(0, (duration - 6) / 2), min(6, duration)
        ffmpeg('-i', source, '-map', '0:v:0', '-an', '-vf',
               'scale=480:480:force_original_aspect_ratio=decrease:force_divisible_by=2',
               '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '26', '-preset', 'fast', '-threads', '1', '-movflags', '+faststart', clip)
        ffmpeg('-i', source_poster, '-frames:v', '1', '-vf',
               'scale=480:480:force_original_aspect_ratio=decrease', '-q:v', '3', '-threads', '1', poster)
        ffmpeg('-ss', start, '-t', length, '-i', source, '-filter_complex',
               'fps=6,scale=160:160:force_original_aspect_ratio=decrease:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer',
               '-loop', '0', '-threads', '1', '-filter_complex_threads', '1', gif)
        clip_stream, clip_duration = probe(clip)
        poster_stream, _ = probe(poster)
        gif_stream, gif_duration = probe(gif, frames=True)
        frame_count = int(gif_stream.get('nb_read_frames', 0))
        if clip_stream['codec_name'] != 'h264' or max(clip_stream['width'], clip_stream['height']) > 480:
            raise ValueError('Unexpected mobile video codec/size')
        if abs(clip_duration - duration) > max(0.3, duration * 0.01):
            raise ValueError('Full demonstration was unexpectedly truncated')
        if max(poster_stream['width'], poster_stream['height']) > 480 or poster_stream['codec_name'] != 'mjpeg':
            raise ValueError('Unexpected mobile poster codec/size')
        if not 1 < frame_count <= 38 or max(gif_stream['width'], gif_stream['height']) > 160 or not 0 < gif_duration <= 6.2:
            raise ValueError('GIF must contain bounded, genuine continuous frames')
        item = dict(sourceID=row['id'], sourceName=row['name'], variant=variant,
                    fileName=clip.name, posterFileName=poster.name, previewGIFFileName=gif.name,
                    sourceURL=video_url, sourcePosterURL=poster_url,
                    sourceSHA256=digest(source), sourcePosterSHA256=digest(source_poster),
                    sourceBytes=source_bytes, sourcePosterBytes=poster_bytes,
                    fileSHA256=digest(clip), posterSHA256=digest(poster), previewGIFSHA256=digest(gif),
                    fileBytes=clip.stat().st_size, posterBytes=poster.stat().st_size, previewGIFBytes=gif.stat().st_size,
                    durationSeconds=clip_duration, sourceDurationSeconds=duration,
                    sourceWidth=source_stream['width'], sourceHeight=source_stream['height'],
                    width=clip_stream['width'], height=clip_stream['height'], codec='h264',
                    previewGIFStartSeconds=start, previewGIFDurationSeconds=gif_duration, frames=frame_count,
                    previewGIFWidth=gif_stream['width'], previewGIFHeight=gif_stream['height'],
                    authorizationBasis='userConfirmed', changes=CHANGES)
        write_json(proof, item)
        return item

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(args.workers, 8))) as pool:
        pending = {pool.submit(build, task): task for task in tasks}
        for future in concurrent.futures.as_completed(pending):
            row, variant, _, _, _ = pending[future]
            try:
                results.append(future.result())
            except Exception as error:
                failures.append(dict(sourceID=row['id'], variant=variant, error=str(error)[:1400]))
            if (len(results) + len(failures)) % 25 == 0 or len(results) + len(failures) == len(tasks):
                print(json.dumps(dict(completed=len(results), failed=len(failures), total=len(tasks))), flush=True)
    results.sort(key=lambda value: (value['sourceID'], value['variant']))
    write_json(args.cache / 'import-failures.json', failures)
    if failures:
        raise SystemExit('Incomplete import: %d variants failed; see ignored cache/import-failures.json' % len(failures))
    summary = dict(sourceRecords=len(rows), variants=len(results), sourceVideoBytes=sum(x['sourceBytes'] for x in results),
                   bundledBytes=sum(x['fileBytes'] + x['posterBytes'] + x['previewGIFBytes'] for x in results),
                   frames=sum(x['frames'] for x in results), maximumGIFDuration=max(x['previewGIFDurationSeconds'] for x in results))
    if complete:
        write_json(MEDIA / 'fed-media-manifest.json', dict(formatVersion=1, sourceRepository=REPOSITORY,
                   sourceDatasetSHA256=digest(args.dataset), authorizationBasis='userConfirmed',
                   authorizationDate='2026-10-28', metadataLicense='MIT', metadataAuthor='Arham Wani',
                   metadataLicenseURL=REPOSITORY + '/blob/main/LICENSE', changes=CHANGES, summary=summary, entries=results))
        (MEDIA / 'fed-NOTICE.md').write_text(
            '# Free Exercise DB media provenance\n\nSource: ' + REPOSITORY + '\n\n'
            'Metadata/code: MIT, Copyright (c) 2026 Arham Wani. The full upstream MIT notice accompanies the dataset.\n\n'
            'Media acceptance: explicitly confirmed by the personal App owner on 2026-10-28. '
            'This does not assert independent verification of the upstream seller rights or that MIT covers the videos. '
            'Upstream README states that the maintainer purchased the footage from a seller and cannot confirm its original provenance.\n\n'
            + CHANGES + '\n\nEvery available male/female source variant is preserved separately. '
            'Per-file original URLs, original hashes, output hashes and decode checks: fed-media-manifest.json. '
            'These demonstrations are not complete teaching courses or personal movement clearance.\n\n'
            '## Upstream MIT notice (code and exercise metadata)\n\n'
            'MIT License\n\nCopyright (c) 2026 Arham Wani\n\n'
            'Permission is hereby granted, free of charge, to any person obtaining a copy '
            'of this software and associated documentation files (the "Software"), to deal '
            'in the Software without restriction, including without limitation the rights '
            'to use, copy, modify, merge, publish, distribute, sublicense, and/or sell '
            'copies of the Software, and to permit persons to whom the Software is '
            'furnished to do so, subject to the following conditions:\n\n'
            'The above copyright notice and this permission notice shall be included in all '
            'copies or substantial portions of the Software.\n\n'
            'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR '
            'IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, '
            'FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE '
            'AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER '
            'LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, '
            'OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE '
            'SOFTWARE.\n', encoding='utf-8')
    print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
