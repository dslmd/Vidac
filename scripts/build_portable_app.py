#!/usr/bin/env python3
"""Assemble an arm64 macOS app without an external Python/Homebrew runtime.

No model weights, settings, user media, credentials or recognition caches are
copied. A build machine needs the project venv, IINA's matching mpv libraries,
Xcode command line tools, and internet for the pinned upstream source files.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request

PROJECT = Path(__file__).resolve().parents[1]
CACHE = PROJECT / "build/portable-cache"
DOWNLOADS = {
    "python-3.12.10-macos11.pkg": (
        "https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg",
        "8373e58da4ea146b3eb1c1f9834f19a319440b6b679b06050b1f9ee3237aa8e4",
    ),
    "ffmpeg-7.1.1.tar.xz": (
        "https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz",
        "733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1",
    ),
}
FFMPEG_FLAGS = [
    "--disable-shared", "--enable-static", "--disable-ffplay", "--disable-doc",
    "--disable-debug", "--disable-autodetect", "--disable-network", "--disable-asm",
    "--disable-encoders", "--enable-encoder=pcm_f32le", "--disable-muxers",
    "--enable-muxer=pcm_f32le", "--disable-filters", "--enable-filter=aresample,aformat,anull",
    "--disable-bsfs", "--disable-devices", "--enable-small",
    "--extra-cflags=-mmacosx-version-min=26.0", "--extra-ldflags=-mmacosx-version-min=26.0",
]


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def output(args):
    return subprocess.check_output([str(a) for a in args], text=True)


def prepare():
    CACHE.mkdir(parents=True, exist_ok=True)
    for name, (url, expected) in DOWNLOADS.items():
        path = CACHE / name
        if not path.exists():
            print(f"Downloading {name}", flush=True)
            urllib.request.urlretrieve(url, path)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"SHA256 mismatch: {name}")
    python_pkg = CACHE / "python-pkg"
    if not python_pkg.exists():
        run(["/usr/sbin/pkgutil", "--expand-full", CACHE / "python-3.12.10-macos11.pkg", python_pkg])
    ffmpeg_source = CACHE / "ffmpeg-7.1.1"
    if not ffmpeg_source.exists():
        with tarfile.open(CACHE / "ffmpeg-7.1.1.tar.xz") as archive:
            archive.extractall(CACHE, filter="data")
    prefix = CACHE / "ffmpeg-static"
    marker = prefix / "vidac-build-flags.json"
    existing_flags = json.loads(marker.read_text()) if marker.exists() else None
    if not (prefix / "bin/ffmpeg").exists() or not (prefix / "bin/ffprobe").exists() or existing_flags != FFMPEG_FLAGS:
        env = os.environ.copy()
        env["MACOSX_DEPLOYMENT_TARGET"] = "26.0"
        log = CACHE / "ffmpeg-build.log"
        with log.open("w") as handle:
            for args in [["./configure", f"--prefix={prefix}", *FFMPEG_FLAGS], ["make", "-j8"], ["make", "install"]]:
                run(args, cwd=ffmpeg_source, env=env, stdout=handle, stderr=subprocess.STDOUT)
        marker.write_text(json.dumps(FFMPEG_FLAGS))
    muxers = subprocess.run([str(prefix / "bin/ffmpeg"), "-hide_banner", "-muxers"], check=True, capture_output=True, text=True).stdout
    if not re.search(r"\bf32le\b", muxers):
        raise RuntimeError("FFmpeg build does not provide the f32le output required by subtitle decoding")
    return python_pkg, prefix


def copy_tree(source: Path, dest: Path):
    shutil.copytree(source, dest, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"))


def is_macho(path: Path):
    if path.suffix in {".o", ".a"}:
        return False  # build-time objects are not loaded by the app
    try:
        with path.open("rb") as handle:
            return handle.read(4) in {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf"}
    except (OSError, IsADirectoryError):
        return False


class Relocator:
    def __init__(self, app: Path, iina: Path):
        self.app = app
        self.frameworks = app / "Contents/Frameworks"
        self.iina = iina / "Contents/Frameworks"
        self.sources: dict[Path, Path] = {}
        self.records = []
        self.commands = {}
        self.internal_names = {}
        for path in app.rglob("*"):
            if path.is_file() and not path.is_symlink():
                self.internal_names.setdefault(path.name, []).append(path)

    def thin(self, path: Path):
        arches = output(["/usr/bin/lipo", "-archs", path]).strip().split()
        if "arm64" not in arches:
            raise RuntimeError(f"Missing arm64 slice: {path}")
        if len(arches) > 1:
            temp = path.with_name(path.name + ".arm64-tmp")
            run(["/usr/bin/lipo", path, "-thin", "arm64", "-output", temp])
            temp.replace(path)
        path.chmod(path.stat().st_mode | 0o200)

    def deps(self, path: Path):
        dependencies = [line.strip().split(" (", 1)[0] for line in output(["/usr/bin/otool", "-L", path]).splitlines()[1:] if " (" in line]
        # otool -L lists LC_ID_DYLIB first for a dylib. Its original build
        # install ID is not a dependency and need not exist on this Mac.
        own_id = self.dylib_id(path)
        own_ids = {own_id, "@rpath/" + path.name} if own_id else set()
        return [dep for dep in dependencies if dep not in own_ids]

    def load_commands(self, path: Path):
        if path not in self.commands:
            self.commands[path] = output(["/usr/bin/otool", "-l", path])
        return self.commands[path]

    def dylib_id(self, path: Path):
        matches = re.findall(r"cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.*?) \(offset", self.load_commands(path))
        return matches[0] if matches else None

    def rpaths(self, path: Path):
        text = self.load_commands(path)
        return re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", text)

    def minimum_macos(self, path: Path):
        text = self.load_commands(path)
        versions = re.findall(r"\bminos (\d+(?:\.\d+)*)", text)
        versions += re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+)*)", text)
        return max(versions, key=lambda v: tuple(map(int, v.split(".")))) if versions else None

    def resolve(self, owner: Path, dep: str):
        if dep.startswith("/Library/Frameworks/Python.framework/"):
            return self.frameworks / "Python.framework" / dep.split("/Python.framework/", 1)[1]
        if dep.startswith("@loader_path/"):
            return (owner.parent / dep.removeprefix("@loader_path/")).resolve()
        if dep.startswith("@executable_path/"):
            return (self.app / "Contents/MacOS" / dep.removeprefix("@executable_path/")).resolve()
        if dep.startswith("@rpath/"):
            relative = dep.removeprefix("@rpath/")
            candidates = [self.frameworks / relative, self.iina / relative, owner.parent / relative]
            for rpath in self.rpaths(owner):
                expanded = rpath.replace("@loader_path", str(owner.parent)).replace("@executable_path", str(self.app / "Contents/MacOS"))
                if not expanded.startswith("@"):
                    candidates.append(Path(expanded) / relative)
            for path in candidates:
                if path.exists():
                    return path.resolve()
            # Some wheel extensions (Numba's optional OpenMP pool) omit an
            # rpath even though another included wheel supplies the library.
            # Only accept an unambiguous already-bundled basename.
            internal = self.internal_names.get(Path(relative).name, [])
            if len(internal) == 1:
                return internal[0].resolve()
            raise RuntimeError(f"Unresolved dependency {dep} from {owner}")
        return Path(dep)

    def relocate(self):
        queue = [p for p in self.app.rglob("*") if p.is_file() and not p.is_symlink() and is_macho(p)]
        seen = set()
        while queue:
            owner = queue.pop(0).resolve()
            if owner in seen:
                continue
            seen.add(owner)
            self.thin(owner)
            original_rpaths = self.rpaths(owner)
            for dep in self.deps(owner):
                if dep.startswith(("/usr/lib/", "/System/Library/")):
                    continue
                if dep.startswith("/opt/homebrew/") and Path(dep).name == "libmpv.2.dylib":
                    resolved = self.iina / "libmpv.2.dylib"
                else:
                    resolved = self.resolve(owner, dep)
                if not resolved.exists():
                    raise RuntimeError(f"Missing dependency: {dep} from {owner}")
                if not resolved.is_relative_to(self.app):
                    destination = self.frameworks / resolved.name
                    if not destination.exists():
                        shutil.copy2(resolved, destination)
                        self.sources[destination] = resolved
                        queue.append(destination)
                    resolved = destination
                target = "@loader_path/" + os.path.relpath(resolved, owner.parent)
                if dep != target:
                    run(["/usr/bin/install_name_tool", "-change", dep, target, owner], stderr=subprocess.DEVNULL)
            if self.dylib_id(owner):
                run(["/usr/bin/install_name_tool", "-id", "@rpath/" + owner.name, owner], stderr=subprocess.DEVNULL)
            for rpath in original_rpaths:
                if rpath.startswith(("/opt/", "/Users/", "/Library/Frameworks/")):
                    run(["/usr/bin/install_name_tool", "-delete_rpath", rpath, owner], stderr=subprocess.DEVNULL)
            minimum = self.minimum_macos(owner)
            if minimum and (tuple(map(int, minimum.split("."))) + (0, 0))[:3] > (26, 2, 0):
                raise RuntimeError(f"Dependency requires macOS {minimum}, above target 26.2: {owner}")
            self.records.append({"path": str(owner.relative_to(self.app)), "minimum_macos": minimum, "dependencies": self.deps(owner)})
        # Audit every non-system dependency after all rewrites. Relative load
        # commands must resolve inside the app; no build-machine fallback.
        for record in self.records:
            owner = self.app / record["path"]
            for dep in record["dependencies"]:
                if dep.startswith(("/usr/lib/", "/System/Library/")):
                    continue
                if dep.startswith("@rpath/") and dep == "@rpath/" + owner.name:
                    continue  # dylib's own install ID, not a dependency
                if not dep.startswith("@loader_path/") or not self.resolve(owner, dep).is_relative_to(self.app):
                    raise RuntimeError(f"External runtime reference remains: {owner}: {dep}")
        return sorted(seen, key=lambda x: len(x.parts), reverse=True)


IDENTITY = os.environ.get("VIDAC_SIGN_IDENTITY", "-")
ENTITLEMENTS = PROJECT / "macos/Vidac.entitlements"


def sign(app: Path, binaries):
    """Sign inside-out. With a Developer ID identity every Mach-O gets the
    hardened runtime and a secure timestamp, as notarization requires;
    executables additionally get the JIT entitlements. Ad-hoc otherwise."""
    release = IDENTITY != "-"
    base = ["/usr/bin/codesign", "--force", "--sign", IDENTITY]
    if release:
        base += ["--timestamp", "--options", "runtime"]

    def codesign(target: Path, entitled: bool):
        extra = ["--entitlements", ENTITLEMENTS] if release and entitled else []
        run([*base, *extra, target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def is_executable(path: Path):
        return "EXECUTE" in output(["/usr/bin/otool", "-hv", path])

    main_binary = app / "Contents/MacOS/Vidac"
    for binary in binaries:  # deepest paths first
        if binary != main_binary.resolve():
            codesign(binary, is_executable(binary))
    framework = app / "Contents/Frameworks/Python.framework"
    codesign(framework / "Versions/3.12/Resources/Python.app", True)
    codesign(framework, False)
    codesign(app, True)


def package(args):
    python_pkg, ffmpeg = prepare()
    app = args.output.resolve()
    source = args.app.resolve()
    if app == source or not source.is_dir():
        raise RuntimeError("Build the native app first; output must differ from input")
    if app.exists():
        shutil.rmtree(app)
    copy_tree(source, app)
    runtime = app / "Contents/Resources/runtime"
    runtime.mkdir(parents=True)
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(exist_ok=True)
    python_framework = python_pkg / "Python_Framework.pkg/Payload"
    copy_tree(python_framework, frameworks / "Python.framework")
    # CPython's command-line executable posix_spawns the nested Python.app,
    # which must remain even though Vidac never presents a Python GUI.
    for name in ["Versions/3.12/lib/python3.12/idlelib", "Versions/3.12/lib/python3.12/test", "Versions/3.12/lib/python3.12/config-3.12-darwin", "Versions/3.12/include", "Versions/3.12/share"]:
        path = frameworks / "Python.framework" / name
        if path.is_dir():
            shutil.rmtree(path)
    for name in ["Headers", "Versions/3.12/Headers"]:
        (frameworks / "Python.framework" / name).unlink(missing_ok=True)
    for child in (frameworks / "Python.framework/Versions/3.12/bin").iterdir():
        if child.name != "python3.12":
            child.unlink() if child.is_file() or child.is_symlink() else shutil.rmtree(child)
    copy_tree(PROJECT / "vidac", runtime / "vidac")
    copy_tree(PROJECT / ".venv/lib/python3.12/site-packages", runtime / "site-packages")
    shutil.rmtree(runtime / "site-packages/build", ignore_errors=True)  # stray setuptools output, not a package
    bin_dir = runtime / "bin"
    bin_dir.mkdir()
    for name in ["ffmpeg", "ffprobe"]:
        shutil.copy2(ffmpeg / "bin" / name, bin_dir / name)
    run(["swiftc", "-O", "-parse-as-library", "-target", "arm64-apple-macos26.0", PROJECT / "swift/apple_translate.swift", "-o", bin_dir / "apple-translate"])
    wrapper = '''#!/bin/bash
set -euo pipefail
VIDAC_RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONHOME="$VIDAC_RUNTIME/../../Frameworks/Python.framework/Versions/3.12"
export PYTHONPATH="$VIDAC_RUNTIME:$VIDAC_RUNTIME/site-packages"
export PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
export PATH="$VIDAC_RUNTIME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export SSL_CERT_FILE="$VIDAC_RUNTIME/site-packages/certifi/cacert.pem"
export NUMBA_CACHE_DIR="${HOME}/Library/Caches/vidac/numba"
mkdir -p "$NUMBA_CACHE_DIR"
exec "$PYTHONHOME/bin/python3.12" "$@"
'''
    (bin_dir / "python3").write_text(wrapper)
    (bin_dir / "python3").chmod(0o755)
    (runtime / "run.sh").write_text('''#!/bin/bash
set -euo pipefail
VIDAC_RUNTIME="$(cd "$(dirname "$0")" && pwd)"
cd "$VIDAC_RUNTIME"
exec "$VIDAC_RUNTIME/bin/python3" -m vidac "$@"
''')
    (runtime / "run.sh").chmod(0o755)
    (app / "Contents/Resources/runtime-path.txt").unlink(missing_ok=True)
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["LSMinimumSystemVersion"] = "26.2"
    info_path.write_bytes(plistlib.dumps(info))
    relocator = Relocator(app, args.iina.resolve())
    binaries = relocator.relocate()
    notices = app / "Contents/Resources/ThirdParty"
    notices.mkdir()
    shutil.copy2(PROJECT / "PACKAGING.md", notices / "PACKAGING.md")
    shutil.copy2(PROJECT / "THIRD_PARTY_NOTICES.md", notices / "THIRD_PARTY_NOTICES.md")
    shutil.copy2(args.iina / "Contents/Resources/Credits.rtf", notices / "IINA-dependency-credits.rtf")
    for name in ["COPYING.LGPLv2.1", "COPYING.GPLv2", "COPYING.LGPLv3", "COPYING.GPLv3", "LICENSE.md"]:
        shutil.copy2(CACHE / "ffmpeg-7.1.1" / name, notices / name)
    source_dir = notices / "source"
    source_dir.mkdir()
    shutil.copy2(CACHE / "ffmpeg-7.1.1.tar.xz", source_dir / "ffmpeg-7.1.1.tar.xz")
    manifest = {
        "architecture": "arm64", "minimum_macos": "26.2", "python": "3.12.10",
        "iina_version": plistlib.loads((args.iina / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"],
        "iina_build": plistlib.loads((args.iina / "Contents/Info.plist").read_bytes())["CFBundleVersion"],
        "iina_mpv_original_sha256": hashlib.sha256((args.iina / "Contents/Frameworks/libmpv.2.dylib").read_bytes()).hexdigest(),
        "downloads": [{"file": n, "url": u, "sha256": s} for n, (u, s) in DOWNLOADS.items()],
        "ffmpeg_configuration": FFMPEG_FLAGS,
        "native_dependencies": relocator.records,
        "copied_libraries": [{"path": str(dest.relative_to(app)), "source": "IINA/Contents/Frameworks/" + original.name if original.is_relative_to(args.iina.resolve()) else original.name, "original_sha256": hashlib.sha256(original.read_bytes()).hexdigest()} for dest, original in relocator.sources.items()],
        "signing": "ad-hoc; not Developer ID signed or notarized" if IDENTITY == "-" else "Developer ID, hardened runtime; notarization is a separate step (scripts/release.sh)",
        "model_weights_included": False,
    }
    (notices / "build-manifest.json").write_text(json.dumps(manifest, indent=2))
    sign(app, binaries)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    # The official CPython launcher needs its nested Python.app. Exercise the
    # actual embedded interpreter, not just its dylib load commands.
    run([bin_dir / "python3", "-c", "import ssl,numpy,mlx.core,mlx_whisper; assert numpy.arange(3).sum() == 3"], env={**os.environ, "PATH": "/usr/bin:/bin"})
    print(f"Portable app: {app}", flush=True)
    if not args.no_archive:
        archive = app.parent / f"Vidac-{info['CFBundleShortVersionString']}-arm64.zip"
        archive.unlink(missing_ok=True)
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
        (archive.parent / (archive.name + ".sha256")).write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n")
        print(f"Archive: {archive}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=PROJECT / "build/Vidac.app")
    parser.add_argument("--output", type=Path, default=PROJECT / "dist/Vidac.app")
    parser.add_argument("--iina", type=Path, default=Path(os.environ.get("IINA_APP_PATH", "/Applications/IINA.app")))
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--no-archive", action="store_true")
    args = parser.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    with (CACHE / ".build.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Another portable build is already running; wait for it to finish")
        if args.prepare:
            prepare()
        else:
            package(args)


if __name__ == "__main__":
    main()
