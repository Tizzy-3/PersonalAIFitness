#!/usr/bin/env python3
"""Structural checks only; this script never substitutes for Swift/Xcode compilation."""
from pathlib import Path
import json
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

# Swift requires labelled arguments in declaration order. These initialisers alone caused three
# consecutive CI failures, so their order is checked here instead of waiting for a compile error in
# CI. The lists mirror the struct definitions; keep them in sync when a field is added.
CALL_ARGUMENT_ORDER = {
    'LoggedSet': ['id', 'kind', 'loadKG', 'reps', 'durationSeconds', 'distanceMeters',
                  'rpe', 'rir', 'completedAt', 'skipped'],
    'WorkoutExercise': ['id', 'exercise', 'sets', 'restSeconds', 'note', 'skipped',
                        'exertion', 'feelingNote'],
    'PlannedExercise': ['id', 'exercise', 'setCount', 'targetReps', 'targetSeconds', 'restSeconds'],
    'SessionFeedback': ['id', 'sessionID', 'createdAt', 'completedWorkingSets', 'totalSeconds',
                        'perceivedExertion', 'tooHard', 'painReported', 'painAreas', 'barrierNote'],
}


def _call_bodies(content, name):
    """Yield the argument text of every ``name( ... )`` call, quoting-aware.

    Declarations (``init(``, ``func``, ``struct``) are skipped so a signature is not mistaken for a
    call, and quoted text is skipped so a string containing a colon is not read as an argument.
    """
    needle = name + '('
    index = 0
    while True:
        start = content.find(needle, index)
        if start < 0:
            return
        line_start = content.rfind('\n', 0, start) + 1
        if re.search(r'\b(func|init|struct|class|enum)\b', content[line_start:start]):
            index = start + len(needle)
            continue
        depth, i, body = 0, start + len(needle) - 1, []
        in_string = False
        escaped = False
        closed = False
        while i < len(content):
            ch = content[i]
            if in_string:
                body.append(ch)
                if escaped:
                    escaped = False
                elif ch == '\\':
                    escaped = True
                elif ch == '"':
                    in_string = False
            elif ch == '"':
                in_string = True
                body.append(ch)
            elif ch == '(':
                depth += 1
                if depth > 1:
                    body.append(ch)
            elif ch == ')':
                depth -= 1
                if depth == 0:
                    yield ''.join(body)
                    index = i + 1
                    closed = True
                    break
                body.append(ch)
            else:
                body.append(ch)
            i += 1
        if not closed:
            return


def _top_level_labels(text):
    """Label names of the call's own arguments, ignoring nested calls and string contents."""
    depth = 0
    in_string = False
    escaped = False
    labels = []
    token = ''
    for ch in text:
        if in_string:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
            continue
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        elif depth == 0 and ch == ',':
            if ':' in token:
                labels.append(token.split(':', 1)[0].strip())
            token = ''
            continue
        if depth == 0:
            token += ch
    if ':' in token:
        labels.append(token.split(':', 1)[0].strip())
    return labels


def main():
    errors = []
    swift = list((ROOT / 'Sources').rglob('*.swift')) + list((ROOT / 'Packages').rglob('*.swift')) + list((ROOT / 'Tests').rglob('*.swift'))
    for path in swift:
        content = path.read_text(encoding='utf-8-sig')
        if '�' in content:
            errors.append('Invalid UTF-8 replacement in ' + str(path.relative_to(ROOT)))
        if 'fatalError(' in content:
            errors.append('Unrecoverable error path in ' + str(path.relative_to(ROOT)))
        if re.search(r'ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|BEGIN (?:RSA |EC )?PRIVATE KEY', content):
            errors.append('Possible credential in source: ' + str(path.relative_to(ROOT)))
        for type_name, order in CALL_ARGUMENT_ORDER.items():
            rank = {label: position for position, label in enumerate(order)}
            for body in _call_bodies(content, type_name):
                labels = [l for l in _top_level_labels(body) if l in rank]
                ranks = [rank[l] for l in labels]
                if ranks != sorted(ranks):
                    errors.append(
                        'Argument order in %s(%s) at %s must follow the declaration order'
                        % (type_name, ', '.join(labels), str(path.relative_to(ROOT))))
    info = plistlib.loads((ROOT / 'Sources/PersonalFitness/Resources/Info.plist').read_bytes())
    entitlements = plistlib.loads((ROOT / 'Sources/PersonalFitness/Resources/PersonalFitness.entitlements').read_bytes())
    if not info.get('NSHealthShareUsageDescription') or entitlements.get('com.apple.developer.healthkit') is not True:
        errors.append('HealthKit read capability or description missing')
    if info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads'):
        errors.append('Unexpected global transport security bypass')
    for path in (ROOT / 'Sources/PersonalFitness/Assets.xcassets').rglob('Contents.json'):
        data = json.loads(path.read_text(encoding='utf-8-sig'))
        for image in data.get('images', []):
            if image.get('filename') and not (path.parent / image['filename']).is_file():
                errors.append('Missing asset: ' + image['filename'])
    icon = (ROOT / 'Sources/PersonalFitness/Assets.xcassets/AppIcon.appiconset/AppIcon.png').read_bytes()
    if icon[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack('>II', icon[16:24]) != (1024, 1024):
        errors.append('App icon must be a 1024x1024 PNG')
    project = ROOT / 'PersonalFitness.xcodeproj/project.pbxproj'
    if not project.exists():
        errors.append('Generate the Xcode project first')
    else:
        text = project.read_text(encoding='utf-8')
        for path in (ROOT / 'Sources').rglob('*.swift'):
            if path.relative_to(ROOT).as_posix() not in text:
                errors.append('App source missing from project: ' + path.name)
        for path in (ROOT / 'Tests').rglob('*.swift'):
            if path.relative_to(ROOT).as_posix() not in text:
                errors.append('App test missing from project: ' + path.name)
        for setting in ['com.personalfitness.private', '27.0', 'Packages/FitnessCore']:
            if setting not in text:
                errors.append('Required project setting missing: ' + setting)
        ET.parse(ROOT / 'PersonalFitness.xcodeproj/xcshareddata/xcschemes/PersonalFitness.xcscheme')
    workflow = (ROOT / '.github/workflows/ios-trial.yml').read_text(encoding='utf-8')
    for action in re.findall(r'uses:\s*([^\s#]+)', workflow):
        if not re.fullmatch(r'[^@]+@[0-9a-f]{40}', action):
            errors.append('Unpinned workflow dependency: ' + action)
    if errors:
        raise SystemExit('\n'.join(errors))
    # App methods such as testConnection are not XCTest methods.
    test_sources = [p for p in swift if 'Tests' in p.relative_to(ROOT).parts]
    methods = sum(len(re.findall(r'func test[A-Za-z0-9_]+\(', p.read_text(encoding='utf-8-sig'))) for p in test_sources)
    print('STRUCTURAL CHECKS PASSED')
    print('Swift files: %d; XCTest methods present: %d (NOT executed by this check)' % (len(swift), methods))
    print('Checked: source inclusion, capability/plist structure, assets, scheme XML, action pins, credential patterns.')
    print('NOT checked here: Swift compilation, XCTest execution, signing, iOS device or HealthKit behavior.')


if __name__ == '__main__':
    main()
