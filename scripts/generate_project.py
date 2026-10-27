#!/usr/bin/env python3
"""Generate the small deterministic Xcode project without third-party generators."""
from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OBJECTS = {}


def ident(name):
    return hashlib.sha1(name.encode('utf-8')).hexdigest()[:24].upper()


def obj(identity_key, isa, **fields):
    key = ident(identity_key)
    OBJECTS[key] = dict(isa=isa, **fields)
    return key


def serialize(value, depth=0):
    indent = '\t' * depth
    if isinstance(value, dict):
        return '{\n' + ''.join(indent + '\t' + json.dumps(str(k)) + ' = ' + serialize(v, depth + 1) + ';\n' for k, v in value.items()) + indent + '}'
    if isinstance(value, list):
        return '(\n' + ''.join(indent + '\t' + serialize(v, depth + 1) + ',\n' for v in value) + indent + ')'
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def configurations(name, settings):
    refs = []
    for mode in ('Debug', 'Release'):
        values = dict(settings)
        values['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if mode == 'Debug' else '-O'
        if mode == 'Debug':
            values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
            values['ENABLE_TESTABILITY'] = 'YES'
            values['GCC_OPTIMIZATION_LEVEL'] = '0'
            values['ONLY_ACTIVE_ARCH'] = 'YES'
        refs.append(obj(name + '.' + mode, 'XCBuildConfiguration', buildSettings=values, name=mode))
    return obj(name + '.configurations', 'XCConfigurationList', buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')


def source_files(folder, prefix):
    refs, builds = [], []
    for path in sorted((ROOT / folder).rglob('*.swift')):
        relative = path.relative_to(ROOT).as_posix()
        ref = obj(prefix + relative, 'PBXFileReference', lastKnownFileType='sourcecode.swift', name=path.name, path=relative, sourceTree='<group>')
        refs.append(ref)
        builds.append(obj(prefix + '.build.' + relative, 'PBXBuildFile', fileRef=ref))
    return refs, builds


def main():
    app_refs, app_builds = source_files('Sources/PersonalFitness', 'app.')
    test_refs, test_builds = source_files('Tests/PersonalFitnessTests', 'tests.')
    if not app_builds or not test_builds:
        raise SystemExit('App and test sources must exist before generating the project.')
    project_id, app_target_id, test_target_id = ident('project'), ident('app.target'), ident('test.target')
    app_product = obj('app.product', 'PBXFileReference', explicitFileType='wrapper.application', includeInIndex=0, path='PersonalFitness.app', sourceTree='BUILT_PRODUCTS_DIR')
    test_product = obj('test.product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', includeInIndex=0, path='PersonalFitnessTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
    assets = obj('assets', 'PBXFileReference', lastKnownFileType='folder.assetcatalog', path='Sources/PersonalFitness/Assets.xcassets', sourceTree='<group>')
    media = obj('exercise.media', 'PBXFileReference', lastKnownFileType='folder', path='Sources/PersonalFitness/Resources/ExerciseMedia', sourceTree='<group>')
    resources = obj('app.resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=[obj('assets.build', 'PBXBuildFile', fileRef=assets), obj('media.build', 'PBXBuildFile', fileRef=media)], runOnlyForDeploymentPostprocessing=0)
    package = obj('core.package', 'XCLocalSwiftPackageReference', relativePath='Packages/FitnessCore')
    core_product = obj('core.product', 'XCSwiftPackageProductDependency', package=package, productName='FitnessCore')
    test_core_product = obj('test.core.product', 'XCSwiftPackageProductDependency', package=package, productName='FitnessCore')
    framework_phase = obj('app.frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[obj('core.build', 'PBXBuildFile', productRef=core_product)], runOnlyForDeploymentPostprocessing=0)
    test_framework_phase = obj('test.frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[obj('test.core.build', 'PBXBuildFile', productRef=test_core_product)], runOnlyForDeploymentPostprocessing=0)
    app_source_phase = obj('app.sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=app_builds, runOnlyForDeploymentPostprocessing=0)
    test_source_phase = obj('test.sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=test_builds, runOnlyForDeploymentPostprocessing=0)
    app_group = obj('app.group', 'PBXGroup', children=app_refs, name='App Sources', sourceTree='<group>')
    test_group = obj('test.group', 'PBXGroup', children=test_refs, name='App Tests', sourceTree='<group>')
    resources_group = obj('resources.group', 'PBXGroup', children=[assets, media], name='Resources', sourceTree='<group>')
    products_group = obj('products.group', 'PBXGroup', children=[app_product, test_product], name='Products', sourceTree='<group>')
    main_group = obj('main.group', 'PBXGroup', children=[app_group, test_group, resources_group, products_group], sourceTree='<group>')
    shared = dict(CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', SDKROOT='iphoneos', IPHONEOS_DEPLOYMENT_TARGET='27.0', SWIFT_VERSION='6.0', SWIFT_STRICT_CONCURRENCY='complete', ENABLE_USER_SCRIPT_SANDBOXING='YES', DEBUG_INFORMATION_FORMAT='dwarf-with-dsym')
    project_configs = configurations('project', shared)
    app_settings = dict(PRODUCT_NAME='PersonalFitness', PRODUCT_MODULE_NAME='PersonalFitness', PRODUCT_BUNDLE_IDENTIFIER='com.personalfitness.private', MARKETING_VERSION='0.4.2', CURRENT_PROJECT_VERSION='27', TARGETED_DEVICE_FAMILY='1', GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE='Sources/PersonalFitness/Resources/Info.plist', CODE_SIGN_ENTITLEMENTS='Sources/PersonalFitness/Resources/PersonalFitness.entitlements', CODE_SIGN_STYLE='Automatic', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', SUPPORTS_MACCATALYST='NO', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/Frameworks'], ENABLE_PREVIEWS='YES')
    app_configs = configurations('app', app_settings)
    test_settings = dict(PRODUCT_NAME='PersonalFitnessTests', PRODUCT_BUNDLE_IDENTIFIER='com.personalfitness.private.tests', TARGETED_DEVICE_FAMILY='1', GENERATE_INFOPLIST_FILE='YES', TEST_HOST='$(BUILT_PRODUCTS_DIR)/PersonalFitness.app/PersonalFitness', BUNDLE_LOADER='$(TEST_HOST)', CODE_SIGN_STYLE='Automatic', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'])
    test_configs = configurations('tests', test_settings)
    proxy = obj('test.proxy', 'PBXContainerItemProxy', containerPortal=project_id, proxyType=1, remoteGlobalIDString=app_target_id, remoteInfo='PersonalFitness')
    dependency = obj('test.dependency', 'PBXTargetDependency', target=app_target_id, targetProxy=proxy)
    obj('app.target', 'PBXNativeTarget', buildConfigurationList=app_configs, buildPhases=[app_source_phase, framework_phase, resources], buildRules=[], dependencies=[], name='PersonalFitness', packageProductDependencies=[core_product], productName='PersonalFitness', productReference=app_product, productType='com.apple.product-type.application')
    obj('test.target', 'PBXNativeTarget', buildConfigurationList=test_configs, buildPhases=[test_source_phase, test_framework_phase], buildRules=[], dependencies=[dependency], name='PersonalFitnessTests', packageProductDependencies=[test_core_product], productName='PersonalFitnessTests', productReference=test_product, productType='com.apple.product-type.bundle.unit-test')
    obj('project', 'PBXProject', attributes=dict(BuildIndependentTargetsInParallel='YES', LastUpgradeCheck='2700', TargetAttributes={app_target_id:dict(CreatedOnToolsVersion='27.0', SystemCapabilities={'com.apple.HealthKit':dict(enabled=1)}),test_target_id:dict(CreatedOnToolsVersion='27.0',TestTargetID=app_target_id)}), buildConfigurationList=project_configs, compatibilityVersion='Xcode 14.0', developmentRegion='zh_CN', hasScannedForEncodings=0, knownRegions=['en', 'zh-Hans', 'Base'], mainGroup=main_group, packageReferences=[package], productRefGroup=products_group, projectDirPath='', projectRoot='', targets=[app_target_id, test_target_id])
    root = dict(archiveVersion=1, classes={}, objectVersion=56, objects=OBJECTS, rootObject=project_id)
    project_dir = ROOT / 'PersonalFitness.xcodeproj'
    project_dir.mkdir(exist_ok=True)
    (project_dir / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + serialize(root) + '\n', encoding='utf-8')
    scheme = ET.Element('Scheme', LastUpgradeVersion='2700', version='1.3')
    build_action = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
    entries = ET.SubElement(build_action, 'BuildActionEntries')
    def reference(parent, key, name):
        ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=key, BuildableName=name, BlueprintName=name.split('.')[0], ReferencedContainer='container:PersonalFitness.xcodeproj')
    entry = ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES', buildForRunning='YES', buildForProfiling='YES', buildForArchiving='YES', buildForAnalyzing='YES')
    reference(entry, app_target_id, 'PersonalFitness.app')
    action = ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', shouldUseLaunchSchemeArgsEnv='YES')
    tests = ET.SubElement(action, 'Testables')
    testable = ET.SubElement(tests, 'TestableReference', skipped='NO')
    reference(testable, test_target_id, 'PersonalFitnessTests.xctest')
    expansion = ET.SubElement(action, 'MacroExpansion')
    reference(expansion, app_target_id, 'PersonalFitness.app')
    launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0', useCustomWorkingDirectory='NO', ignoresPersistentStateOnLaunch='NO', debugDocumentVersioning='YES', debugServiceExtension='internal', allowLocationSimulation='YES')
    reference(ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0'), app_target_id, 'PersonalFitness.app')
    ET.SubElement(scheme, 'ProfileAction', buildConfiguration='Release', shouldUseLaunchSchemeArgsEnv='YES', savedToolIdentifier='', useCustomWorkingDirectory='NO', debugDocumentVersioning='YES')
    ET.SubElement(scheme, 'AnalyzeAction', buildConfiguration='Debug')
    ET.SubElement(scheme, 'ArchiveAction', buildConfiguration='Release', revealArchiveInOrganizer='YES')
    scheme_dir = project_dir / 'xcshareddata' / 'xcschemes'
    scheme_dir.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(scheme).write(scheme_dir / 'PersonalFitness.xcscheme', encoding='utf-8', xml_declaration=True)
    print('Project generated: %d app files, %d test files' % (len(app_refs), len(test_refs)))


if __name__ == '__main__':
    main()
