#!/usr/bin/env python3
"""Regenerate ios/SpektraLab.xcodeproj/project.pbxproj from the filesystem.

    python3 ios/Tools/gen-project.py            # write
    python3 ios/Tools/gen-project.py --check    # exit 1 if the checked-in file is stale

The upstream macOS project generates its own Xcode project the same way
(`Tools/gen-project.py` there), and for the same reasons: the project file is
derived from what is on disk, so adding a source file cannot be forgotten, and
the file is reviewable as a diff rather than as whatever Xcode happened to
write.

Object ids are derived from paths *relative to the project* (the first 24 hex
characters of a sha1), so two checkouts of the same tree agree and a worktree's
regeneration does not conflict with the main one's. Running this twice
produces a byte-identical file.

**The engine's C++ joins the app target as sources**, the way it does on
macOS: the engine is a set of translation units under `engine/src/`, and a
separate static-library target would add a second place for the include paths
to drift. Three groups are excluded, and the reasons are not the same:

  * `src/io/` and `src/desktop/` -- the Windows hosts' LibRaw/native-TIFF I/O
    and the desktop controller. iOS decodes with ImageIO (`ImageDecoder.swift`)
    and has no desktop.
  * `src/gpu/vulkan_gpu.cpp` -- the Vulkan backend. iOS is Metal.
  * `src/pipeline/windows_unported.cpp` and `src/pipeline/imprint_raster.cpp`
    -- Windows-only stubs and the non-Apple imprint rasteriser. The Apple
    path rasterises the edge print and the date with CoreText, in
    `overscan.cpp`.

Two things about the engine are *not* handled here, on purpose:

  * its Metal kernels are compiled by `ios/Tools/build-engine.sh`, not by
    Xcode -- with safe-math, which the engine's startup probe insists on.
  * its baked constants and profiles are synced into
    `ios/SpektraLab/Resources/engine/` by the same script, and ride along in
    the folder reference below.
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]          # ios/
REPO = ROOT.parent                                   # the repository root
ENGINE = REPO / "engine"

APP = "SpektraLab"
PRODUCT_NAME = "SpektraLab"
IOS_MIN = "16.0"
MARKETING_VERSION = "1.0.0"
BUILD_NUMBER = "1"

# Signing, from the environment: a development certificate is not in this
# repository and must not be.
#
#     SPEKTRAFILM_SIGN_IDENTITY="Apple Development: NAME (TEAMID)" \
#     SPEKTRAFILM_TEAM_ID=TEAMID python3 ios/Tools/gen-project.py
#
# The CI workflow passes these from its secrets, so the same project file
# builds signed on the runner without anyone editing it.
SIGN_IDENTITY = os.environ.get("SPEKTRAFILM_SIGN_IDENTITY", "-")
TEAM_ID = os.environ.get("SPEKTRAFILM_TEAM_ID", "")
PROVISIONING_PROFILE = os.environ.get("SPEKTRAFILM_PROVISIONING_PROFILE", "")

# The bundle id the provisioning profile is bound to. It has to match the
# profile exactly -- a profile is issued for one bundle id -- so it is
# configuration rather than a constant here.
BUNDLE_ID = os.environ.get("SPEKTRAFILM_BUNDLE_ID") or "com.hanze.spektralab"


def uid(key: str) -> str:
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()


def engine_sources() -> list[Path]:
    """The engine's translation units for iOS, in a stable order."""
    excluded_dirs = {"io", "desktop"}
    excluded_files = {
        "gpu/vulkan_gpu.cpp",
        "pipeline/windows_unported.cpp",
        "pipeline/imprint_raster.cpp",
    }
    root = ENGINE / "src"
    return sorted(
        p for p in root.rglob("*.cpp")
        if p.relative_to(root).parts[0] not in excluded_dirs
        and p.relative_to(root).as_posix() not in excluded_files
    )


def relative_to_project(path: Path) -> str:
    """A path spelled relative to the .xcodeproj's directory."""
    return Path(os.path.relpath(path, ROOT)).as_posix()


def file_type(p: Path) -> str:
    return {
        ".swift": "sourcecode.swift",
        ".metal": "sourcecode.metal",
        ".cpp": "sourcecode.cpp.cpp",
        ".h": "sourcecode.c.h",
        ".hpp": "sourcecode.cpp.h",
        ".plist": "text.plist.xml",
        ".entitlements": "text.plist.entitlements",
        ".xcassets": "folder.assetcatalog",
        ".md": "net.daringfireball.markdown",
        ".py": "text.script.python",
        ".sh": "text.script.sh",
    }.get(p.suffix, "folder")


class Project:
    def __init__(self):
        self.objects: list[str] = []

    def add(self, id_: str, body: str, comment: str = ""):
        c = f" /* {comment} */" if comment else ""
        self.objects.append(f"\t\t{id_}{c} = {body};")

    def group(self, dir_: Path, target_files: list[tuple[str, Path]],
              name: str | None = None) -> str:
        gid = uid("group:" + relative_to_project(dir_))
        children = []
        for entry in sorted(dir_.iterdir(), key=lambda p: (p.is_file(), p.name.lower())):
            if entry.name.startswith("."):
                continue
            if entry.is_dir() and entry.suffix != ".xcassets" and entry.name != "Resources":
                if entry.name in ("build", "DerivedData"):
                    continue
                children.append((self.group(entry, target_files), entry.name))
            else:
                fid = uid("file:" + relative_to_project(entry))
                ft = file_type(entry)
                if entry.name == "Resources":
                    self.add(fid,
                             '{isa = PBXFileReference; lastKnownFileType = folder; '
                             'path = Resources; sourceTree = "<group>"; }',
                             "Resources")
                else:
                    self.add(fid,
                             f'{{isa = PBXFileReference; lastKnownFileType = {ft}; '
                             f'path = "{entry.name}"; sourceTree = "<group>"; }}',
                             entry.name)
                children.append((fid, entry.name))
                target_files.append((fid, entry))
        kids = ",\n".join(f"\t\t\t\t{cid} /* {cname} */" for cid, cname in children)
        self.add(gid,
                 f'{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{kids}\n\t\t\t);\n'
                 f'\t\t\tpath = "{name or dir_.name}";\n\t\t\tsourceTree = "<group>";\n\t\t}}',
                 name or dir_.name)
        return gid


def build() -> str:
    p = Project()
    app_files: list[tuple[str, Path]] = []
    tools_files: list[tuple[str, Path]] = []
    app_group = p.group(ROOT / APP, app_files)
    tools_group = p.group(ROOT / "Tools", tools_files)

    # The engine's translation units, as references outside the project tree.
    engine_files: list[tuple[str, Path]] = []
    engine_children = []
    for src in engine_sources():
        fid = uid("file:engine:" + relative_to_project(src))
        p.add(fid,
              f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.cpp.cpp; '
              f'name = "{src.name}"; path = "{relative_to_project(src)}"; '
              f'sourceTree = SOURCE_ROOT; }}', src.name)
        engine_children.append((fid, src.name))
        engine_files.append((fid, src))
    engine_group = uid("group:engine")
    kids = ",\n".join(f"\t\t\t\t{cid} /* {cname} */" for cid, cname in engine_children)
    p.add(engine_group,
          f'{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{kids}\n\t\t\t);\n'
          f'\t\t\tname = Engine;\n\t\t\tsourceTree = "<group>";\n\t\t}}', "Engine")

    app_product = uid("product:app")
    p.add(app_product,
          f'{{isa = PBXFileReference; explicitFileType = wrapper.application; '
          f'includeInIndex = 0; path = {PRODUCT_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }}',
          f"{PRODUCT_NAME}.app")
    products = uid("group:products")
    p.add(products,
          f'{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app_product}\n\t\t\t);\n'
          f'\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t}}', "Products")
    main_group = uid("group:main")
    p.add(main_group,
          f'{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app_group},\n'
          f'\t\t\t\t{engine_group},\n\t\t\t\t{tools_group},\n\t\t\t\t{products}\n\t\t\t);\n'
          f'\t\t\tsourceTree = "<group>";\n\t\t}}')

    def phase(kind: str, files: list[tuple[str, Path]], pred, tag: str) -> str:
        ids = []
        for fid, path in files:
            if pred(path):
                bid = uid(f"build:{tag}:{relative_to_project(path)}")
                p.add(bid, f"{{isa = PBXBuildFile; fileRef = {fid}; }}", path.name)
                ids.append(f"\t\t\t\t{bid} /* {path.name} */")
        pid = uid(f"phase:{tag}:{kind}")
        p.add(pid,
              f'{{\n\t\t\tisa = {kind};\n\t\t\tbuildActionMask = 2147483647;\n'
              f'\t\t\tfiles = (\n' + ",\n".join(ids) + "\n\t\t\t);\n"
              f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}}', tag)
        return pid

    is_src = lambda q: q.suffix in (".swift", ".metal", ".cpp")
    is_res = lambda q: q.suffix == ".xcassets" or q.name == "Resources"
    app_sources = phase("PBXSourcesBuildPhase", app_files + engine_files, is_src, "app-sources")
    app_resources = phase("PBXResourcesBuildPhase", app_files, is_res, "app-resources")
    app_frameworks = phase("PBXFrameworksBuildPhase", [], lambda q: False, "app-frameworks")

    # The engine's build settings.
    engine_cfg = {
        "CLANG_CXX_LANGUAGE_STANDARD": '"c++20"',
        "CLANG_CXX_LIBRARY": '"libc++"',
        "GCC_C_LANGUAGE_STANDARD": "c11",
        # `$(SRCROOT)` is the directory holding the .xcodeproj, which is
        # `ios/`. The engine is at the repository root, so the path up from
        # there is one level, not two: `$(SRCROOT)/../engine/...`. Two
        # levels points above the repository, and the bridging header's
        # `#import "spektrafilm/spk_engine.h"` then fails with "file not
        # found" -- which is what it did.
        "HEADER_SEARCH_PATHS": "(\n" + "".join(
            f'\t\t\t\t\t"$(SRCROOT)/../engine/{sub}",\n'
            for sub in ("include", "src", "src/core", "third_party/metal-cpp")
        ) + "\t\t\t\t)",
        "SWIFT_OBJC_BRIDGING_HEADER": f'"{APP}/Service/{APP}-Bridging-Header.h"',
        # Metal, QuartzCore and Accelerate are the ones the engine links;
        # CoreGraphics and CoreText are what `overscan.cpp` rasterises the
        # edge print and the date with. All five exist on iOS.
        "OTHER_LDFLAGS": '"-framework Metal -framework QuartzCore -framework CoreText '
                         '-framework CoreGraphics -framework Accelerate"',
        # metal-cpp's headers use `objc_msgSend` directly and manage their own
        # retain/release; ARC must not be applied to them.
        "CLANG_ENABLE_OBJC_ARC": "NO",
    }

    common = {
        **engine_cfg,
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "IPHONEOS_DEPLOYMENT_TARGET": IOS_MIN,
        "SDKROOT": "iphoneos",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
        # Manual for both cases. Automatic signing needs a DEVELOPMENT_TEAM
        # and an Apple account to choose a certificate; a CI runner with no
        # signing secrets has neither, and `xcodebuild archive` then fails
        # validation with "Archive Missing Bundle Identifier". Manual with
        # CODE_SIGN_IDENTITY "-" is ad-hoc -- no team, no certificate -- and
        # with real secrets PROVISIONING_PROFILE_SPECIFIER + the named
        # identity drive it instead.
        "CODE_SIGN_STYLE": "Manual",
        "CODE_SIGN_IDENTITY": f'"{SIGN_IDENTITY}"',
        "DEVELOPMENT_TEAM": f'"{TEAM_ID}"',
        "CLANG_ENABLE_MODULES": "YES",
        "MARKETING_VERSION": MARKETING_VERSION,
        "CURRENT_PROJECT_VERSION": BUILD_NUMBER,
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "GENERATE_INFOPLIST_FILE": "NO",
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        # The app's own canvas shader may use fast math; the engine's kernels
        # never go through Xcode's metal compiler, so they cannot inherit it.
        "MTL_FAST_MATH": "YES",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        # The engine reads its resources out of the bundle at runtime.
        "ENABLE_BITCODE": "NO",
    }
    if PROVISIONING_PROFILE:
        common["PROVISIONING_PROFILE_SPECIFIER"] = f'"{PROVISIONING_PROFILE}"'

    app_cfg = {
        **common,
        "PRODUCT_NAME": PRODUCT_NAME,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "INFOPLIST_FILE": f"{APP}/Info.plist",
        "CODE_SIGN_ENTITLEMENTS": f"{APP}/{APP}.entitlements",
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
    }

    def cfg(tag: str, name: str, settings: dict, extra: dict) -> str:
        cid = uid(f"cfg:{tag}:{name}")
        merged = {**settings, **extra}
        body = "\n".join(f"\t\t\t\t{k} = {v};" for k, v in sorted(merged.items()))
        p.add(cid,
              f'{{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{body}\n'
              f'\t\t\t}};\n\t\t\tname = {name};\n\t\t}}', name)
        return cid

    debug = {"SWIFT_OPTIMIZATION_LEVEL": '"-Onone"', "DEBUG_INFORMATION_FORMAT": "dwarf",
             "ENABLE_TESTABILITY": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
             # The engine's C++ is -O2 in Debug too: at -O0 its host-side work
             # is an order of magnitude slower, and the Debug app is judged
             # by that. Swift stays -Onone for debugging.
             "GCC_OPTIMIZATION_LEVEL": "2",
             "ONLY_ACTIVE_ARCH": "YES",
             # A Debug build goes to a simulator or a device, not to a
             # distribution, so it does not need a provisioning profile.
             "CODE_SIGNING_ALLOWED": "YES"}
    release = {"SWIFT_OPTIMIZATION_LEVEL": '"-O"', "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
               "SWIFT_COMPILATION_MODE": "wholemodule",
               "ONLY_ACTIVE_ARCH": "NO",
               "VALIDATE_PRODUCT": "YES"}

    def cfg_list(tag: str, settings: dict) -> str:
        d = cfg(tag, "Debug", settings, debug)
        r = cfg(tag, "Release", settings, release)
        lid = uid(f"cfglist:{tag}")
        p.add(lid,
              f'{{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n'
              f'\t\t\t\t{d} /* Debug */,\n\t\t\t\t{r} /* Release */\n\t\t\t);\n'
              f'\t\t\tdefaultConfigurationIsVisible = 0;\n'
              f'\t\t\tdefaultConfigurationName = Release;\n\t\t}}', tag)
        return lid

    # A pre-build check, not a build step: it reports rather than bakes, so a
    # build that skipped the kernel compilation fails with a sentence instead
    # of an engine error at runtime.
    check_script = uid("phase:app:check-resources")
    p.add(check_script,
          '{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\tbuildActionMask = 2147483647;'
          '\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);'
          '\n\t\t\tname = "Check engine resources";\n\t\t\toutputPaths = (\n\t\t\t);'
          '\n\t\t\trunOnlyForDeploymentPostprocessing = 0;'
          '\n\t\t\tshellPath = /bin/sh;'
          '\n\t\t\tshellScript = "\\"$SRCROOT/Tools/check-engine-resources.sh\\"\\n";'
          '\n\t\t}', "Check engine resources")

    app_target = uid("target:app")
    project = uid("project")
    p.add(app_target,
          f'{{\n\t\t\tisa = PBXNativeTarget;\n'
          f'\t\t\tbuildConfigurationList = {cfg_list("app", app_cfg)};\n'
          f'\t\t\tbuildPhases = (\n\t\t\t\t{check_script},\n\t\t\t\t{app_sources},\n'
          f'\t\t\t\t{app_frameworks},\n\t\t\t\t{app_resources}\n\t\t\t);\n'
          f'\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n'
          f'\t\t\tname = {APP};\n\t\t\tproductName = {APP};\n'
          f'\t\t\tproductReference = {app_product};\n'
          f'\t\t\tproductType = "com.apple.product-type.application";\n\t\t}}', APP)

    proj_cfg = cfg_list("project", {
        "SWIFT_VERSION": "6.0", "IPHONEOS_DEPLOYMENT_TARGET": IOS_MIN,
        "SDKROOT": "iphoneos", "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "ONLY_ACTIVE_ARCH": "YES",
    })
    p.add(project,
          f'{{\n\t\t\tisa = PBXProject;\n'
          f'\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n'
          f'\t\t\t\tLastSwiftUpdateCheck = 1600;\n\t\t\t\tLastUpgradeCheck = 1600;\n'
          f'\t\t\t}};\n'
          f'\t\t\tbuildConfigurationList = {proj_cfg};\n'
          f'\t\t\tcompatibilityVersion = "Xcode 14.0";\n'
          f'\t\t\tdevelopmentRegion = en;\n'
          f'\t\t\thasScannedForEncodings = 0;\n'
          f'\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase\n\t\t\t);\n'
          f'\t\t\tmainGroup = {main_group};\n'
          f'\t\t\tproductRefGroup = {products};\n'
          f'\t\t\tprojectDirPath = "";\n\t\t\t\tprojectRoot = "";\n'
          f'\t\t\ttargets = (\n\t\t\t\t{app_target}\n\t\t\t);\n\t\t}}', "Project object")

    body = "\n".join(p.objects)
    return (f"// !$*UTF8*$!\n{{\n\tarchiveVersion = 1;\n\tclasses = {{\n\t}};\n"
            f"\tobjectVersion = 56;\n\tobjects = {{\n{body}\n\t}};\n"
            f"\trootObject = {project} /* Project object */;\n}}\n")


def scheme(text: str) -> str:
    """The shared scheme, which `xcodebuild` needs for `-archivePath`.

    A generated project has no scheme unless something writes one, and
    `xcodebuild` insists on a scheme for anything that names an output path:
    "-archivePath is required when not using -exportArchive" and
    "-derivedDataPath" wants one too.

    The scheme's `BlueprintIdentifier` is the target's id, which is a sha1 of
    a fixed string -- so it is the same on every machine and does not have to
    be read back out of the project file.
    """
    target = uid("target:app")
    product = uid("product:app")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target}"
               BuildableName = "{APP}.app"
               BlueprintName = "{APP}"
               ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "{APP}.app"
            BlueprintName = "{APP}"
            ReferencedContainer = "container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "{APP}.app"
            BlueprintName = "{APP}"
            ReferencedContainer = "container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""


def main() -> None:
    out = ROOT / f"{APP}.xcodeproj" / "project.pbxproj"
    text = build()
    scheme_text = scheme(text)
    scheme_dir = ROOT / f"{APP}.xcodeproj" / "xcshareddata" / "xcschemes"
    scheme_path = scheme_dir / f"{APP}.xcscheme"

    if "--check" in sys.argv:
        stale = False
        if not out.exists() or out.read_text(encoding="utf-8") != text:
            print("project.pbxproj is stale; run ios/Tools/gen-project.py")
            stale = True
        if not scheme_path.exists() or scheme_path.read_text(encoding="utf-8") != scheme_text:
            print(f"{APP}.xcscheme is stale; run ios/Tools/gen-project.py")
            stale = True
        if stale:
            sys.exit(1)
        print("project.pbxproj and the scheme are current")
        return

    out.parent.mkdir(exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print(f"wrote {out}")
    scheme_dir.mkdir(parents=True, exist_ok=True)
    scheme_path.write_text(scheme_text, encoding="utf-8")
    print(f"wrote {scheme_path}")


if __name__ == "__main__":
    main()
