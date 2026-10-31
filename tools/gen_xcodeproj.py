#!/usr/bin/env python3
"""Generates RiftRivals.xcodeproj (project.pbxproj + shared scheme).

The project compiles the app sources (App/RiftRivals) together with the
platform-independent engine (Sources/RiftCore) into one iOS app target.
Re-run after adding or removing source files:

    python3 tools/gen_xcodeproj.py
"""
import hashlib
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PROJ = os.path.join(ROOT, "RiftRivals.xcodeproj")
APP_DIR = "App/RiftRivals"
CORE_DIR = "Sources/RiftCore"
# Test-only infrastructure is not shipped in the app.
CORE_EXCLUDE = {"Session/NetTestbed.swift", "Net/SimulatedNetwork.swift"}
BUNDLE_ID = "com.surproductions.riftrivals"
VERSION = "1.0.1"
BUILD = "2"


def oid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def swift_files(base, exclude=()):
    out = []
    for dirpath, _, files in os.walk(os.path.join(ROOT, base)):
        for f in files:
            if f.endswith(".swift"):
                rel = os.path.relpath(os.path.join(dirpath, f), os.path.join(ROOT, base))
                if rel not in exclude:
                    out.append(rel)
    return sorted(out)


def q(s):
    return '"%s"' % s if any(c in s for c in " -+@$()/=,;") else s


def main():
    app_files = swift_files(APP_DIR)
    core_files = swift_files(CORE_DIR, CORE_EXCLUDE)

    P = oid("project")
    MAIN_GROUP = oid("group", "main")
    APP_GROUP = oid("group", "app")
    CORE_GROUP = oid("group", "core")
    PRODUCTS = oid("group", "products")
    TARGET = oid("target")
    PRODUCT = oid("product")
    SRC_PHASE = oid("phase", "sources")
    RES_PHASE = oid("phase", "resources")
    FW_PHASE = oid("phase", "frameworks")
    PROJ_CFG = oid("cfglist", "project")
    TGT_CFG = oid("cfglist", "target")
    ASSETS_REF = oid("ref", "assets")
    ASSETS_BF = oid("bf", "assets")
    PLIST_REF = oid("ref", "plist")

    objs = []
    file_refs = []
    build_files = []
    app_children = []
    core_children = []

    for f in app_files:
        r, b = oid("ref", "app", f), oid("bf", "app", f)
        file_refs.append(f'\t\t{r} /* {os.path.basename(f)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(f)}; sourceTree = "<group>"; }};')
        build_files.append(f'\t\t{b} /* {os.path.basename(f)} in Sources */ = {{isa = PBXBuildFile; fileRef = {r}; }};')
        app_children.append(r)
    for f in core_files:
        r, b = oid("ref", "core", f), oid("bf", "core", f)
        file_refs.append(f'\t\t{r} /* {os.path.basename(f)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(f)}; sourceTree = "<group>"; }};')
        build_files.append(f'\t\t{b} /* {os.path.basename(f)} in Sources */ = {{isa = PBXBuildFile; fileRef = {r}; }};')
        core_children.append(r)
    file_refs.append(f'\t\t{ASSETS_REF} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = \"Resources/Assets.xcassets\"; sourceTree = "<group>"; }};')
    file_refs.append(f'\t\t{PLIST_REF} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    file_refs.append(f'\t\t{PRODUCT} /* RiftRivals.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = RiftRivals.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    build_files.append(f'\t\t{ASSETS_BF} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ASSETS_REF}; }};')

    def children(ids):
        return "\n".join(f"\t\t\t\t{i}," for i in ids)

    groups = f"""\t\t{MAIN_GROUP} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{APP_GROUP},
\t\t\t\t{CORE_GROUP},
\t\t\t\t{PRODUCTS},
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{APP_GROUP} /* RiftRivals */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{children(app_children + [ASSETS_REF, PLIST_REF])}
\t\t\t);
\t\t\tname = RiftRivals;
\t\t\tpath = {q(APP_DIR)};
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{CORE_GROUP} /* RiftCore */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{children(core_children)}
\t\t\t);
\t\t\tname = RiftCore;
\t\t\tpath = {q(CORE_DIR)};
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{PRODUCTS} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{PRODUCT},
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};"""

    src_bfs = [oid("bf", "app", f) for f in app_files] + [oid("bf", "core", f) for f in core_files]

    common_project = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
    }
    debug_project = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
    })
    release_project = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_NS_ASSERTIONS": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
        "VALIDATE_PRODUCT": "YES",
    })
    target_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": BUILD,
        "DEVELOPMENT_TEAM": '""',
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": q(f"{APP_DIR}/Info.plist"),
        "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
        "MARKETING_VERSION": VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": q(BUNDLE_ID),
        "PRODUCT_NAME": "RiftRivals",
        "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "TARGETED_DEVICE_FAMILY": "1",
    }

    def cfg(name, key, settings):
        body = "\n".join(f"\t\t\t\t{k} = {v};" for k, v in sorted(settings.items()))
        return f"""\t\t{oid('cfg', key, name)} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{body}
\t\t\t}};
\t\t\tname = {name};
\t\t}};"""

    configs = "\n".join([
        cfg("Debug", "project", debug_project),
        cfg("Release", "project", release_project),
        cfg("Debug", "target", target_settings),
        cfg("Release", "target", target_settings),
    ])

    pbx = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_refs)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{FW_PHASE} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
{groups}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{TARGET} /* RiftRivals */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {TGT_CFG};
\t\t\tbuildPhases = (
\t\t\t\t{SRC_PHASE},
\t\t\t\t{FW_PHASE},
\t\t\t\t{RES_PHASE},
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = RiftRivals;
\t\t\tproductName = RiftRivals;
\t\t\tproductReference = {PRODUCT};
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{P} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{TARGET} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {PROJ_CFG};
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {MAIN_GROUP};
\t\t\tproductRefGroup = {PRODUCTS};
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{TARGET},
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{RES_PHASE} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{ASSETS_BF},
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{SRC_PHASE} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{children(src_bfs)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
{configs}
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{PROJ_CFG} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{oid('cfg', 'project', 'Debug')},
\t\t\t\t{oid('cfg', 'project', 'Release')},
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{TGT_CFG} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{oid('cfg', 'target', 'Debug')},
\t\t\t\t{oid('cfg', 'target', 'Release')},
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {P} /* Project object */;
}}
"""
    os.makedirs(PROJ, exist_ok=True)
    with open(os.path.join(PROJ, "project.pbxproj"), "w") as f:
        f.write(pbx)

    scheme_dir = os.path.join(PROJ, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    ref = f"""<BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TARGET}"
               BuildableName = "RiftRivals.app"
               BlueprintName = "RiftRivals"
               ReferencedContainer = "container:RiftRivals.xcodeproj">
            </BuildableReference>"""
    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
            {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
            {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    with open(os.path.join(scheme_dir, "RiftRivals.xcscheme"), "w") as f:
        f.write(scheme)
    print(f"wrote {PROJ} ({len(app_files)} app + {len(core_files)} core sources)")


if __name__ == "__main__":
    main()
