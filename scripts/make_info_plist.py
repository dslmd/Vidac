#!/usr/bin/env python3
"""Write Vidac's Info.plist. The format table below is the single list of
video formats the app registers for; the app reads it back at run time."""
import plistlib
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "io.github.dslmd.vidac"
BUILD = "6"

# Content types macOS already declares.
SYSTEM_TYPES = [
    "public.movie", "public.video", "public.mpeg-4", "com.apple.m4v-video",
    "com.apple.quicktime-movie", "public.avi", "public.mpeg", "public.mpeg-2-video",
    "public.mpeg-2-transport-stream", "public.avchd-mpeg-2-transport-stream",
    "public.3gpp", "public.3gpp2", "public.dv-movie", "org.webmproject.webm",
    "com.microsoft.windows-media-wmv", "com.microsoft.advanced-systems-format",
    "com.adobe.flash.video", "com.real.realmedia", "com.real.realmedia-vbr",
    "org.xiph.ogv", "org.smpte.mxf", "public.flc-animation",
]
SYSTEM_EXTENSIONS = (
    "mp4 m4v mov qt avi mpg mpeg mpe m2v ts mts m2ts 3gp 3gpp 3g2 3gp2 dv webm "
    "wmv asf flv f4v rm rmvb ogv ogm mxf fli flc"
).split()
# Formats without a system declaration. (identifier, description, extensions, imported?)
DECLARED = [
    ("org.matroska.mkv", "Matroska Video", "mkv mk3d", True),
    (BUNDLE_ID + ".mpeg-stream", "MPEG Stream", "tp trp m2t m2p mpv m1v mp2v vob mod tod", False),
    (BUNDLE_ID + ".raw-video", "Raw Video Stream", "h264 264 h265 265 hevc avc vc1 obu ivf y4m", False),
    (BUNDLE_ID + ".legacy-video", "Video", "divx xvid rv ogx gxf nut nuv wtv dvr-ms bik smk mj2 mjpg amv", False),
]


def declaration(identifier, description, extensions):
    return {
        "UTTypeIdentifier": identifier,
        "UTTypeDescription": description,
        "UTTypeConformsTo": ["public.movie"],
        "UTTypeIconFile": "Vidac.icns",
        "UTTypeTagSpecification": {"public.filename-extension": extensions.split()},
    }


def main():
    output = Path(sys.argv[1])
    version = (PROJECT / "VERSION").read_text().strip()
    extensions = SYSTEM_EXTENSIONS + [e for _, _, group, _ in DECLARED for e in group.split()]
    assert len(extensions) == len(set(extensions)), "duplicate extension"
    info = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleName": "Vidac",
        "CFBundleDisplayName": "Vidac",
        "CFBundleExecutable": "Vidac",
        "CFBundlePackageType": "APPL",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleDevelopmentRegion": "en",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": BUILD,
        "CFBundleIconFile": "Vidac.icns",
        "LSMinimumSystemVersion": "26.0",
        "LSApplicationCategoryType": "public.app-category.video",
        "NSHighResolutionCapable": True,
        "NSSupportsAutomaticGraphicsSwitching": True,
        "NSPrincipalClass": "NSApplication",
        "NSHumanReadableCopyright": "© 2026 Vidac contributors. GNU GPL v3 or later.",
        "CFBundleDocumentTypes": [{
            "CFBundleTypeName": "Video",
            "CFBundleTypeRole": "Viewer",
            "LSHandlerRank": "Default",
            "CFBundleTypeIconFile": "Vidac.icns",
            "LSItemContentTypes": SYSTEM_TYPES + [d[0] for d in DECLARED],
            "CFBundleTypeExtensions": extensions,
        }],
        "UTImportedTypeDeclarations": [declaration(i, d, e) for i, d, e, imported in DECLARED if imported],
        "UTExportedTypeDeclarations": [declaration(i, d, e) for i, d, e, imported in DECLARED if not imported],
    }
    output.write_bytes(plistlib.dumps(info))


if __name__ == "__main__":
    main()
