#!/usr/bin/env python3
"""Structural checks only; this script never substitutes for Swift/Xcode compilation."""
from pathlib import Path
import json
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def main():
    errors = []
    swift = list((ROOT / 'Sources').rglob('*.swift')) + list((ROOT / 'Packages').rglob('*.swift')) + list((ROOT / 'Tests').rglob('*.swift'))
    for path in swift:
        content = path.read_text(encoding='utf-8-sig')
        if '\ufffd' in content:
            errors.append('Invalid UTF-8 replacement in ' + str(path.relative_to(ROOT)))
        if 'fatalError(' in content:
            errors.append('Unrecoverable error path in ' + str(path.relative_to(ROOT)))
        if re.search(r'ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|BEGIN (?:RSA |EC )?PRIVATE KEY', content):
            errors.append('Possible credential in source: ' + str(path.relative_to(ROOT)))
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
    methods = sum(len(re.findall(r'func test[A-Za-z0-9_]+\(', p.read_text(encoding='utf-8-sig'))) for p in swift)
    print('STRUCTURAL CHECKS PASSED')
    print('Swift files: %d; XCTest methods present: %d (NOT executed by this check)' % (len(swift), methods))
    print('Checked: source inclusion, capability/plist structure, assets, scheme XML, action pins, credential patterns.')
    print('NOT checked here: Swift compilation, XCTest execution, signing, iOS device or HealthKit behavior.')


if __name__ == '__main__':
    main()
