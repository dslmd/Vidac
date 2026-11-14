# Portable Apple Silicon build

`bash build_app.sh --portable` builds `dist/Vidac.app`, a ZIP and a SHA256 file.
`bash build_app.sh --portable --install` also installs that exact portable app.
The target is **Apple Silicon, macOS 26.2 or later**. Intel Macs are not supported
by this MLX build. A second physical Mac has not yet been tested.

Without `VIDAC_SIGN_IDENTITY` the result is ad-hoc signed. `scripts/release.sh`
produces the Developer ID signed, notarized and stapled archive; see
docs/RELEASING.md. Vidac itself is licensed GPL-3.0-or-later.

## Build inputs

The build machine needs Xcode command line tools, the project Python 3.12 venv,
Homebrew's mpv development headers, and an official IINA installation. Set
`IINA_APP_PATH` to its path if it is not `/Applications/IINA.app`. The packaged
libmpv and its matched dependent dylibs come from IINA 1.4.4 in this build; no
IINA application executable, UI code, settings or user data is copied.

The package script downloads the following pinned upstream artifacts over HTTPS
and checks their SHA256 before use:

- CPython 3.12.10 macOS installer from python.org. It is **extracted, not
  installed**. Its Python.framework is embedded and load commands are relocated.
- FFmpeg 7.1.1 source from ffmpeg.org. The audio extraction/probing tools are
  built locally with system dependencies, no external codec libraries, and no
  networking. All demuxers/decoders remain enabled; only PCM float output is
  required by Vidac. Video/network playback uses the embedded mpv engine.

The installed Python packages, including MLX, NumPy and mlx-whisper, are copied
from the project venv. The venv itself and its absolute interpreter symlinks are
not copied. These package versions are recorded by their existing dist-info
metadata. No model weights, media, subtitle caches, account tokens or application
settings are copied. First use of a speech model requires a download; Apple
translation requires a supported Mac with Apple Intelligence enabled and its
system model available.

Every non-system Mach-O dependency is rewritten to an in-app `@loader_path`
reference and audited before signing. The native app chooses Resources/runtime;
its companion launches the embedded Python and ffmpeg tools through relative
paths. A runtime wrapper sets a private NumPy/Numba cache directory under the
current user's Library, disables user site packages and uses certifi's bundled
CA certificate store.

## Third-party licensing and public release

The output includes the Python and Python-package license files already shipped
with their distributions, FFmpeg license texts and its exact source tarball,
IINA's dependency credits, and a build manifest. The manifest identifies copied
native dependencies and their relative load commands.

mpv and some dependent codec/filter libraries can carry GPL obligations. The
IINA dependency build/source provenance is available at:

- https://github.com/iina/iina (version 1.4.4)
- https://github.com/iina/iina/tree/v1.4.4/deps
- https://github.com/iina/homebrew-mpv-iina (the dependency build method used by IINA 1.4.x)
- https://github.com/iina/deps-buildscripts (the newer dependency build method)
- https://github.com/mpv-player/mpv
- https://ffmpeg.org/legal.html
- https://www.python.org/downloads/release/python-31210/

The per-component list is THIRD_PARTY_NOTICES.md, which is also copied into the
app. The IINA libraries are redistributed unmodified apart from install-name
rewriting, thinning to arm64 and re-signing. Update the notices whenever IINA,
the Python packages or FFmpeg are upgraded.

## Verification

Move the app to a directory containing spaces and test with `PATH=/usr/bin:/bin`:

```bash
"Vidac.app/Contents/Resources/runtime/bin/python3" -c 'import mlx.core, mlx_whisper, numpy; print(mlx.core.array([1,2])+1)'
"Vidac.app/Contents/Resources/runtime/bin/ffprobe" -v error -show_entries format=duration -of csv=p=0 sample.mp4
codesign --verify --deep --strict Vidac.app
```

Also test actual audio extraction, transcription and playback after relocation.
Package integrity and local relocation testing do not prove another physical Mac
or every macOS version works. Keep those claims separate in release notes.
