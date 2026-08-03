"""Generate SeedScout.xcodeproj.

Written as a generator rather than a checked-in blob so the project file stays
readable and regenerable. Uses Xcode 16's file-system synchronised groups, so
the whole SeedScout/ folder is a single reference: adding a Swift file needs no
project edit, which is the usual source of merge pain in a pbxproj.

    python3 ios/make_project.py && open ios/SeedScout.xcodeproj
"""

from __future__ import annotations

import hashlib
from pathlib import Path

BUNDLE_ID = "com.garrettcraig.seedscout"
DEPLOYMENT_TARGET = "17.0"
LOCATION_PURPOSE = (
    "SeedScout uses your location to show which native plants have collectible "
    "seed where you are standing."
)


def oid(name: str) -> str:
    """Deterministic 24-hex-character object id."""
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


IDS = {k: oid(k) for k in [
    "project", "target", "productRef", "productsGroup", "mainGroup", "syncGroup",
    "sourcesPhase", "frameworksPhase", "resourcesPhase",
    "projectConfigList", "targetConfigList",
    "projDebug", "projRelease", "targetDebug", "targetRelease",
]}

COMMON_BUILD = f"""
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};
				SDKROOT = iphoneos;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
"""

TARGET_BUILD = f"""
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				MARKETING_VERSION = 1.0;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = SeedScout;
				INFOPLIST_KEY_NSLocationWhenInUseUsageDescription = "{LOCATION_PURPOSE}";
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
"""


def pbxproj() -> str:
    i = IDS
    return f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXFileReference section */
		{i['productRef']} /* SeedScout.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SeedScout.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{i['syncGroup']} /* SeedScout */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = SeedScout; sourceTree = "<group>"; }};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{i['frameworksPhase']} = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{i['mainGroup']} = {{
			isa = PBXGroup;
			children = (
				{i['syncGroup']} /* SeedScout */,
				{i['productsGroup']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{i['productsGroup']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{i['productRef']} /* SeedScout.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{i['target']} /* SeedScout */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {i['targetConfigList']};
			buildPhases = (
				{i['sourcesPhase']},
				{i['frameworksPhase']},
				{i['resourcesPhase']},
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{i['syncGroup']} /* SeedScout */,
			);
			name = SeedScout;
			productName = SeedScout;
			productReference = {i['productRef']} /* SeedScout.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{i['project']} = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{i['target']} = {{
						CreatedOnToolsVersion = 16.0;
					}};
				}};
			}};
			buildConfigurationList = {i['projectConfigList']};
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {i['mainGroup']};
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = {i['productsGroup']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{i['target']} /* SeedScout */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{i['resourcesPhase']} = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{i['sourcesPhase']} = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{i['projDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{COMMON_BUILD}				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{i['projRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{COMMON_BUILD}				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				MTL_ENABLE_DEBUG_INFO = NO;
				SWIFT_COMPILATION_MODE = wholemodule;
				VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
		{i['targetDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{TARGET_BUILD}			}};
			name = Debug;
		}};
		{i['targetRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{TARGET_BUILD}			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{i['projectConfigList']} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{i['projDebug']} /* Debug */,
				{i['projRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{i['targetConfigList']} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{i['targetDebug']} /* Debug */,
				{i['targetRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {i['project']};
}}
"""


SCHEME = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES"
            buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary"
               BlueprintIdentifier = "{IDS['target']}" BuildableName = "SeedScout.app"
               BlueprintName = "SeedScout" ReferencedContainer = "container:SeedScout.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0"
      useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary"
            BlueprintIdentifier = "{IDS['target']}" BuildableName = "SeedScout.app"
            BlueprintName = "SeedScout" ReferencedContainer = "container:SeedScout.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary"
            BlueprintIdentifier = "{IDS['target']}" BuildableName = "SeedScout.app"
            BlueprintName = "SeedScout" ReferencedContainer = "container:SeedScout.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"/>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
</Scheme>
"""


def main() -> None:
    root = Path(__file__).resolve().parent
    proj = root / "SeedScout.xcodeproj"
    (proj / "xcshareddata" / "xcschemes").mkdir(parents=True, exist_ok=True)
    (proj / "project.pbxproj").write_text(pbxproj())
    (proj / "xcshareddata" / "xcschemes" / "SeedScout.xcscheme").write_text(SCHEME)
    print(f"wrote {proj.relative_to(root.parent)}")
    db = root / "SeedScout" / "Resources" / "seedscout_conus.sqlite"
    if db.exists():
        print(f"  bundled database: {db.stat().st_size / 1e6:.1f} MB")
    else:
        print("  WARNING: run etl/build_sqlite.py conus first")


if __name__ == "__main__":
    main()
