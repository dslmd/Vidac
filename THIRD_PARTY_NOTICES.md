# Third-Party Notices

This file lists the third-party software that is bundled in the portable Vidac application bundle (`Vidac.app`) and the licenses it is distributed under. Vidac's own source code is released under GPL-3.0-or-later (see `LICENSE`). The binary release as a whole is distributed under GPL-3.0-or-later, chosen because the bundled libmpv/FFmpeg libraries copied from IINA are built as GPL. Each third-party component listed below keeps its own license; this file does not change them. License texts shipped with the app are in `Contents/Resources/ThirdParty/` (`COPYING.GPLv2`, `COPYING.GPLv3`, `COPYING.LGPLv2.1`, `COPYING.LGPLv3`, `LICENSE.md`, `IINA-dependency-credits.rtf`) and, for Python packages, in each package's `*.dist-info` directory.

How to read the license columns: entries marked "(bundle)" were verified from files or strings inside the app bundle. Entries marked "(upstream)" come from the upstream project's well-known licensing and were not checked against files in the bundle; where a license depends on version or build options, or could not be established, the cell says so. Package versions are stated only where they come from the build manifest, `otool`, package metadata, or strings inside the library.

## Native libraries (from IINA's dependency build)

The files in `Contents/Frameworks/` were copied from the official IINA 1.4.4 (build 168) application. The IINA-built libav* libraries report `--enable-gpl --enable-version3` in their embedded configuration (from `ffmpeg-iina` 7.0.1), and each of libavcodec, libavfilter, libswscale and libpostproc reports "license: GPL version 3 or later" (bundle). The IINA credits file lists only mpv, FFmpeg and some IINA application dependencies; the remaining rows rely on upstream licensing.

| Component / upstream project | Bundled file(s) | License (SPDX) | Upstream source |
|---|---|---|---|
| mpv (libmpv) | `libmpv.2.dylib` | GPL-2.0-or-later as built by IINA (the build reports the `gpl` feature; bundle). mpv is otherwise LGPL-2.1-or-later when built without GPL features. IINA credits describe the libmpv client API as ISC-licensed. | https://github.com/mpv-player/mpv |
| FFmpeg libraries | `libavcodec.61.dylib`, `libavdevice.61.dylib`, `libavfilter.10.dylib`, `libavformat.61.dylib`, `libavutil.59.dylib`, `libswresample.5.dylib`, `libswscale.8.dylib` | LGPL-2.1-or-later by default (IINA credits); GPL-3.0-or-later in IINA's build (`--enable-gpl --enable-version3`; bundle) | https://ffmpeg.org / https://git.ffmpeg.org/ffmpeg.git |
| FFmpeg libpostproc | `libpostproc.58.dylib` | GPL-2.0-or-later upstream (FFmpeg LICENSE.md); reports GPL v3 or later in IINA's build (bundle) | https://ffmpeg.org |
| libplacebo (reports v6.338.2) | `libplacebo.338.dylib` | LGPL-2.1-or-later (upstream) | https://code.videolan.org/videolan/libplacebo |
| libass | `libass.9.dylib` | ISC (upstream) | https://github.com/libass/libass |
| libarchive | `libarchive.13.dylib` | BSD-2-Clause, with some files under other permissive terms (upstream; not verified in detail) | https://github.com/libarchive/libarchive |
| libbluray | `libbluray.2.dylib` | LGPL-2.1-or-later (upstream) | https://code.videolan.org/videolan/libbluray |
| dav1d | `libdav1d.7.dylib` | BSD-2-Clause (upstream) | https://code.videolan.org/videolan/dav1d |
| Rubber Band | `librubberband.2.dylib` | GPL-2.0-or-later (upstream; commercial license also offered by upstream) | https://github.com/breakfastquay/rubberband |
| vid.stab | `libvidstab.1.2.dylib` | GPL-2.0-or-later (upstream) | https://github.com/georgmartius/vid.stab |
| libsoxr | `libsoxr.0.dylib` | LGPL-2.1-or-later (upstream) | https://sourceforge.net/projects/soxr/ |
| libsamplerate | `libsamplerate.0.dylib` | BSD-2-Clause for 0.2.x (upstream; exact version not established from the bundle, so license not verified) | https://github.com/libsndfile/libsamplerate |
| Speex | `libspeex.1.dylib` | BSD-3-Clause (upstream) | https://github.com/xiph/speex |
| zimg | `libzimg.2.dylib` | WTFPL-2.0 (upstream) | https://github.com/sekrit-twc/zimg |
| libwebp / libsharpyuv | `libwebp.7.dylib`, `libwebpmux.3.dylib`, `libsharpyuv.0.dylib` | BSD-3-Clause (upstream) | https://chromium.googlesource.com/webm/libwebp |
| libjxl (JPEG XL) | `libjxl.0.10.dylib`, `libjxl_cms.0.10.dylib`, `libjxl_threads.0.10.dylib` | BSD-3-Clause (upstream) | https://github.com/libjxl/libjxl |
| Highway | `libhwy.1.dylib` | Apache-2.0 OR BSD-3-Clause (upstream) | https://github.com/google/highway |
| Brotli | `libbrotlicommon.1.dylib`, `libbrotlidec.1.dylib`, `libbrotlienc.1.dylib` | MIT (upstream) | https://github.com/google/brotli |
| Snappy | `libsnappy.1.dylib` | BSD-3-Clause (upstream) | https://github.com/google/snappy |
| libjpeg-turbo (reports 3.0.3) | `libjpeg.8.dylib` | IJG AND BSD-3-Clause AND Zlib (upstream; the library identifies itself as libjpeg-turbo in the bundle) | https://github.com/libjpeg-turbo/libjpeg-turbo |
| libpng | `libpng16.16.dylib` | libpng-2.0 (upstream) | https://github.com/pnggroup/libpng |
| FreeType | `libfreetype.6.dylib` | FTL OR GPL-2.0-or-later (upstream) | https://freetype.org |
| HarfBuzz | `libharfbuzz.0.dylib` | MIT (upstream; "Old MIT" text) | https://github.com/harfbuzz/harfbuzz |
| Graphite2 | `libgraphite2.3.dylib` | Upstream offers a multi-license choice (LGPL-2.1-or-later / MPL / GPL-2.0-or-later); exact SPDX expression not verified | https://github.com/silnrsi/graphite |
| FriBidi | `libfribidi.0.dylib` | LGPL-2.1-or-later (upstream) | https://github.com/fribidi/fribidi |
| Fontconfig | `libfontconfig.1.dylib` | HPND-style permissive license (upstream; exact SPDX id not verified) | https://gitlab.freedesktop.org/fontconfig/fontconfig |
| Little CMS 2 | `liblcms2.2.dylib` | MIT (upstream) | https://github.com/mm2/Little-CMS |
| libunibreak | `libunibreak.6.dylib` | Zlib (upstream) | https://github.com/adah1972/libunibreak |
| uchardet | `libuchardet.0.dylib` | MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later (upstream; not verified) | https://gitlab.freedesktop.org/uchardet/uchardet |
| LuaJIT | `libluajit-5.1.2.dylib` | MIT (upstream) | https://github.com/LuaJIT/LuaJIT |
| MuJS | `libmujs.dylib` | ISC (upstream) | https://github.com/ccxvii/mujs |
| shaderc | `libshaderc_shared.1.dylib` | Apache-2.0 (upstream) | https://github.com/google/shaderc |
| Vulkan loader | `libvulkan.1.dylib` | Apache-2.0 (upstream; the library contains Vulkan loader code per strings in the bundle; exact provenance, e.g. a MoltenVK-related build, not verified) | https://github.com/KhronosGroup/Vulkan-Loader |
| GnuTLS | `libgnutls.30.dylib` | LGPL-2.1-or-later for GnuTLS 3.7 and later (upstream; version not established from the bundle, so license not verified) | https://gitlab.com/gnutls/gnutls |
| Nettle / Hogweed | `libnettle.8.dylib`, `libhogweed.6.dylib` | LGPL-3.0-or-later OR GPL-2.0-or-later (upstream, Nettle 3.x) | https://git.lysator.liu.se/nettle/nettle |
| GMP (reports 6.3.0) | `libgmp.10.dylib` | LGPL-3.0-or-later OR GPL-2.0-or-later (upstream, GMP 6.x) | https://gmplib.org |
| libtasn1 | `libtasn1.6.dylib` | LGPL-2.1-or-later (upstream; the command-line tools are GPL) | https://www.gnu.org/software/libtasn1/ |
| p11-kit | `libp11-kit.0.dylib` | BSD-3-Clause (upstream) | https://github.com/p11-glue/p11-kit |
| libidn2 | `libidn2.0.dylib` | GPL-2.0-or-later OR LGPL-3.0-or-later (upstream) | https://gitlab.com/libidn/libidn2 |
| libunistring | `libunistring.5.dylib` | LGPL-3.0-or-later OR GPL-2.0-or-later (upstream, 1.x) | https://www.gnu.org/software/libunistring/ |
| gettext runtime (libintl) | `libintl.8.dylib` | LGPL-2.1-or-later (upstream) | https://www.gnu.org/software/gettext/ |
| GLib | `libglib-2.0.0.dylib` | LGPL-2.1-or-later (upstream) | https://gitlab.gnome.org/GNOME/glib |
| PCRE2 | `libpcre2-8.0.dylib` | BSD-3-Clause WITH PCRE2-exception (upstream; not verified) | https://github.com/PCRE2Project/pcre2 |
| libsodium | `libsodium.26.dylib` | ISC (upstream) | https://github.com/jedisct1/libsodium |
| ZeroMQ | `libzmq.5.dylib` | MPL-2.0 for 4.3.5 and later; earlier releases were LGPL-3.0-or-later with a static-linking exception (upstream). Version not established from the bundle, so license not verified | https://github.com/zeromq/libzmq |
| BLAKE2 (libb2) | `libb2.1.dylib` | CC0-1.0 OR OpenSSL OR Apache-2.0 (upstream) | https://github.com/BLAKE2/libb2 |
| LZ4 | `liblz4.1.dylib` | BSD-2-Clause for the library (upstream; the command-line tool is GPL-2.0-or-later and is not bundled) | https://github.com/lz4/lz4 |
| XZ Utils (liblzma) | `liblzma.5.dylib` | 0BSD in recent releases; earlier releases are public domain (upstream; version not established, so license not verified) | https://tukaani.org/xz/ |
| Zstandard | `libzstd.1.dylib` | BSD-3-Clause OR GPL-2.0-only (upstream) | https://github.com/facebook/zstd |
| X11 client libraries | `libX11.6.dylib`, `libXau.6.dylib`, `libXdmcp.6.dylib` | X11/MIT-style permissive licenses (upstream); exact SPDX identifiers not verified | https://gitlab.freedesktop.org/xorg/lib |
| XCB | `libxcb.1.dylib`, `libxcb-shape.0.dylib`, `libxcb-shm.0.dylib`, `libxcb-xfixes.0.dylib` | MIT-style (upstream); exact SPDX identifier not verified | https://gitlab.freedesktop.org/xorg/lib/libxcb |

That is 69 library files in `Contents/Frameworks/` (plus `Python.framework`), all listed above and recorded with their original SHA-256 in `Contents/Resources/ThirdParty/build-manifest.json`.

## Python runtime and packages

CPython and the packages below are in `Contents/Frameworks/Python.framework` and `Contents/Resources/runtime/site-packages/`. Versions and licenses are taken from each package's `*.dist-info/METADATA` (License-Expression, License, or Classifier fields). "BSD" without a number means the metadata only says BSD and does not name a clause count.

| Package | Version | License (from package metadata) |
|---|---|---|
| CPython (python.org installer, per the build manifest) | 3.12.10 | Python Software Foundation License (`LICENSE.txt` in `Python.framework/Versions/3.12/lib/python3.12/`; SPDX PSF-2.0) |
| anyio | 4.16.0 | MIT |
| certifi | 2026.10.23 | MPL-2.0 |
| charset-normalizer | 3.5.2 | MIT |
| click | 8.5.1 | BSD-3-Clause |
| filelock | 4.2.10 | MIT |
| fsspec | 2026.9.0 | BSD-3-Clause |
| h11 | 0.16.0 | MIT |
| hf-xet | 1.8.0 | Apache-2.0 |
| httpcore2 | 2.16.0 | BSD-3-Clause |
| httpx2 | 2.16.0 | BSD-3-Clause |
| huggingface_hub | 2.4.0 | Apache-2.0 |
| idna | 3.20 | BSD-3-Clause |
| Jinja2 | 3.1.6 | BSD License (classifier only; see package metadata for clause count) |
| llvmlite | 0.50.0 | BSD-2-Clause AND Apache-2.0 WITH LLVM-exception |
| MarkupSafe | 3.0.4 | BSD-3-Clause |
| mlx | 0.32.4 | MIT |
| mlx-metal | 0.32.4 | MIT |
| mlx-whisper | 0.4.3 | MIT |
| more-itertools | 11.2.1 | MIT |
| mpmath | 1.3.0 | BSD |
| networkx | 3.7 | BSD-3-Clause |
| numba | 0.68.1 | BSD |
| numpy | 2.5.4 | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 |
| packaging | 26.3 | Apache-2.0 OR BSD-2-Clause |
| pip | 26.3 | MIT |
| PyYAML | 6.0.3 | MIT |
| regex | 2026.11.9 | Apache-2.0 AND CNRI-Python |
| requests | 2.34.2 | Apache-2.0 |
| scipy | 1.18.1 | BSD (classifier; the metadata License field holds the license text, which also covers bundled third-party components; see the package's `LICENSE.txt`) |
| setuptools | 84.2.1 | MIT |
| sympy | 1.14.0 | BSD |
| tiktoken | 0.14.0 | MIT |
| torch | 2.15.0 | Apache-2.0 AND Apache-2.0 WITH LLVM-exception AND BSD-2-Clause AND BSD-3-Clause AND BSL-1.0 AND ISC AND MIT AND Zlib |
| tqdm | 4.70.1 | MPL-2.0 AND MIT |
| truststore | 0.10.5 | MIT |
| typing_extensions | 4.16.0 | PSF-2.0 |
| urllib3 | 2.8.0 | MIT |

The table covers CPython plus 37 `*.dist-info` packages. Directories such as `functorch`, `torchgen` (part of torch), `_distutils_hack` (part of setuptools), `_yaml`/`yaml` (PyYAML) and `tiktoken_ext` belong to those packages.

Other native code shipped with these packages and with CPython:

- `scipy/.dylibs/` contains `libgfortran`, `libquadmath` and `libgcc_s` from the GCC runtime. scipy's `LICENSE.txt` lists `libgfortran` and `libgcc` as GPL-3.0-or-later WITH GCC-exception-3.1. The license of `libquadmath` is not stated in the files checked, so it is not verified here (upstream GCC libquadmath is LGPL-2.1-or-later).
- `torch/lib/libomp.dylib` is LLVM OpenMP; torch's bundled third-party license files include `llvm-openmp` (LLVM project license, Apache-2.0 WITH LLVM-exception).
- `Python.framework` also includes OpenSSL 3 (`libssl.3.dylib`, `libcrypto.3.dylib`), Tcl/Tk 8.6 and SQLite 3.47.2 (library directory names). Their licenses (upstream: Apache-2.0 for OpenSSL 3, the Tcl/Tk license, and public domain for SQLite) were not verified from files in the bundle; they come from the python.org installer.
- The `mlx` and `mlx-metal` packages include `libmlx.dylib`, `libjaccl.dylib` and `mlx.metallib`, covered by the packages' MIT license.

## FFmpeg command-line tools

Separately from the IINA libraries above, `Contents/Resources/runtime/bin/ffmpeg` and `ffprobe` are FFmpeg 7.1.1 binaries that were built locally from the official `ffmpeg-7.1.1.tar.xz` (SHA-256 `733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1`) as static, minimal binaries. They do not link any of the IINA FFmpeg libraries or any other third-party library (only Apple system frameworks).

Configure flags, as recorded in `build-manifest.json`:

```
--disable-shared --enable-static --disable-ffplay --disable-doc --disable-debug
--disable-autodetect --disable-network --disable-asm --disable-encoders
--enable-encoder=pcm_f32le --disable-muxers --enable-muxer=pcm_f32le
--disable-filters --enable-filter=aresample,aformat,anull --disable-bsfs
--disable-devices --enable-small
--extra-cflags=-mmacosx-version-min=26.0 --extra-ldflags=-mmacosx-version-min=26.0
```

`--enable-gpl`, `--enable-version3` and `--enable-nonfree` were not used, so these binaries are licensed under LGPL-2.1-or-later as configured. The exact source tarball is shipped inside the app at `Contents/Resources/ThirdParty/source/ffmpeg-7.1.1.tar.xz`. SHA-256 values of the built binaries are in `build-manifest.json`.

## Corresponding source

- IINA 1.4.4 (build 168), the origin of the native libraries: https://github.com/iina/iina (the release tag matching version 1.4.4).
- IINA's dependency build recipes and scripts: https://github.com/iina/homebrew-mpv-iina and https://github.com/iina/deps-buildscripts.
- mpv: https://github.com/mpv-player/mpv
- FFmpeg: https://ffmpeg.org (the IINA library build is `ffmpeg-iina` 7.0.1 per its embedded configure string; the command-line tools are 7.1.1 and their source is in the app, see above).
- Source for the other libraries in the table above is available from the upstream URLs given there.
- Vidac itself, including the build scripts used to assemble this bundle: https://github.com/dslmd/Vidac.
- Python packages and CPython: from PyPI and https://www.python.org/ftp/python/3.12.10/ (see `build-manifest.json` for the installer URL and SHA-256).

The native libraries in `Contents/Frameworks/` are redistributed unmodified from the IINA 1.4.4 application, apart from install-name rewriting (`install_name_tool`), thinning to arm64, and re-signing. No source changes were made to them. The original SHA-256 of each copied library is recorded in `Contents/Resources/ThirdParty/build-manifest.json`.

## Not included

No model weights, media files, or user data are bundled. Whisper models are downloaded by the user on first use and are subject to their own licenses.
