# Frameworks/

## GhosttyKit.xcframework

`GhosttyKit.xcframework` is **not committed to git** — it's ~150MB+ and
machine-specific. `Frameworks/GhosttyKit.xcframework` is a symlink
(gitignored — never commit it) pointing at a locally-built copy outside the
repo, e.g.:

```
Frameworks/GhosttyKit.xcframework -> ~/.cache/argus/ghosttykit/artifacts/<input-hash>/GhosttyKit.xcframework
```

The cache records the resolved Ghostty commit, local patch hash, Zig version,
architecture, and build mode. The script rebuilds when those inputs change,
serializes builds shared by multiple worktrees, validates output before
publication, and links each worktree directly to its immutable matching artifact.

If that symlink is missing or broken (fresh clone, new machine, or the cache
was cleared), `xcodebuild` fails immediately with:

```
fatal error: 'ghostty.h' file not found
```

because the bridging header (`Argus/Resources/Argus-Bridging-Header.h`)
imports it, and `HEADER_SEARCH_PATHS` / `LIBRARY_SEARCH_PATHS` in
`project.yml` point into the (missing) framework. Run
`scripts/build-ghosttykit.sh` to (re)build it — it automates everything
below end-to-end, pinned to a known-good ghostty commit. The manual
walkthrough is kept for troubleshooting and for understanding what the script
is doing.

**New git worktree?** The symlink is gitignored, so a fresh worktree won't
have it — but the built framework lives in `CACHE_DIR`
(`~/.cache/argus/ghosttykit/`), *outside* the repo and shared across all
worktrees. Just run `scripts/build-ghosttykit.sh`: if the cache already holds
a complete framework built from the same inputs, it skips the build and only
(re)creates the symlink (a fraction of a second). Pass `--force` to rebuild the
same inputs.

### Building GhosttyKit from source

Ghostty (https://github.com/ghostty-org/ghostty) is written in Zig and
exposes its terminal engine as a C API (`libghostty`). The macOS xcframework
is one of its own build targets.

> **Build a recent ghostty `main`, not the `v1.3.1` tag.** Two things matter
> here that only exist after v1.3.1:
> 1. The exported `ghostty_*` C API carries `GHOSTTY_API` visibility
>    annotations (`__attribute__((visibility("default")))`), so the symbols
>    survive `ReleaseFast` dead-code elimination. On v1.3.1 a `ReleaseFast`
>    xcframework build silently drops **every** `ghostty_*` symbol.
> 2. `src/build/GhosttyLib.zig` combines the bundled dependency archives via
>    `CombineArchivesStep`. A v1.3.1 arm64-only build produced a static lib
>    missing large chunks of the bundled deps (FreeType, spirv-cross,
>    oniguruma, ...), so Argus failed to link.
>
> The script pins `GHOSTTY_REF` to a known-good `main` commit (`1.3.2-dev`).
> That commit is also the API `Argus/Ghostty/*.swift` is written against —
> see "Keeping Argus in sync" below before bumping it.

**1. Get the exact Zig version Ghostty pins to.**

Check `build.zig.zon`'s `minimum_zig_version` in the Ghostty checkout — as
of the pinned commit this is `0.16.0`. Zig has no backwards compatibility
guarantees across minor versions, so it must match exactly; Homebrew's `zig`
formula is usually newer and will fail to even parse Ghostty's `build.zig`.

```bash
curl -fsSL -o zig.tar.xz \
  "https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz"
# Verify against the sha256 published in https://ziglang.org/download/index.json
# before running it as your build toolchain (build-ghosttykit.sh does this for you):
shasum -a 256 -c - <<<"b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489  zig.tar.xz"
tar xf zig.tar.xz
ZIG=./zig-aarch64-macos-0.16.0/zig
```

(Use `zig-x86_64-macos-0.16.0.tar.xz` on Intel — sha256
`0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7`.)

**2. Fetch the pinned Ghostty commit.**

`GHOSTTY_REF` is a commit SHA, so fetch it explicitly (shallow is fine — the
version comes from `build.zig.zon`, and deps are fetched by the Zig package
manager at build time, no git submodules):

```bash
REF=c959af63d11b524a84c21900372990dbc024b059   # ghostty main, 1.3.2-dev
mkdir ghostty && cd ghostty
git init -q
git remote add origin https://github.com/ghostty-org/ghostty.git
git fetch --depth 1 origin "$REF"
git checkout FETCH_HEAD
```

Apply Argus's archive-naming patch before building:

```bash
git apply /path/to/argus/scripts/patches/ghostty-unique-archive-members.patch
```

The macOS and dcimgui packages both produce an `ext.o`. Once combined into
`libghostty.a`, those names make `dsymutil` look in the wrong object for ImGui
symbols. The patch gives the macOS object a unique basename without changing
its code. `scripts/build-ghosttykit.sh` applies the patch in its temporary
checkout and rejects duplicate archive member names before publishing. The
patch hash is part of the cache key, so existing artifacts remain untouched.

**3. (Zig 0.15.x only) Work around arm64e-only SDK stubs.**

The pinned Zig ≥ 0.16 matches `arm64e-macos` `.tbd` entries itself
([ziglang/zig#31673](https://codeberg.org/ziglang/zig/pulls/31673)), so a
plain `zig build` links fine even against Xcode/CLT ≥ 26.4 SDKs. You only
need this section when overriding `ZIG_VERSION` to 0.15.x (e.g. to build an
older `GHOSTTY_REF`).

Xcode/CLT ≥ 26.4 SDKs ship `.tbd` library stubs that declare only the
`arm64e-macos` target. Zig 0.15.x's Mach-O linker matches `arm64-macos`
entries, finds none, and reports every libSystem symbol as undefined —
breaking *any* `zig build` (not just Ghostty's), starting with the build
runner itself:

```
error: undefined symbol: _abort
error: undefined symbol: __availability_version_check
```

This is upstream [ziglang/zig#31665](https://codeberg.org/ziglang/zig/issues/31665)
(also #31658, #31669); there is no 0.15.x backport. So a 0.15.x build must
instead use an SDK whose `usr/lib/libSystem.tbd` still declares
`arm64-macos`, i.e. any pre-26.4 SDK (e.g. `MacOSX15.x.sdk`).

`build-ghosttykit.sh` looks for such an SDK in
`/Library/Developer/CommandLineTools/SDKs/` and in the user-writable
`~/Library/SDKs/` (checking the `libSystem.tbd` targets, not just the
version number). If neither has one, download one — either the official way
(an Xcode/CLT ≤ 26.3 download from developer.apple.com; Apple ID required)
or from the community [osxcross mirror](https://github.com/joseluisq/macosx-sdks)
used throughout the Zig ecosystem:

```bash
mkdir -p ~/Library/SDKs && cd ~/Library/SDKs
curl -fsSL -O https://github.com/joseluisq/macosx-sdks/releases/download/15.5/MacOSX15.5.sdk.tar.xz
shasum -a 256 -c - <<<"c15cf0f3f17d714d1aa5a642da8e118db53d79429eb015771ba816aa7c6c1cbd  MacOSX15.5.sdk.tar.xz"
tar xf MacOSX15.5.sdk.tar.xz && rm MacOSX15.5.sdk.tar.xz
```

(The [Xcode license terms](https://www.apple.com/legal/sla/docs/xcode.pdf)
apply to these SDKs either way.) To check whether any given SDK is usable —
note `libSystem.tbd` holds one YAML document per re-exported dylib and Zig
only matches against the first document's `targets`:

```bash
awk '/^targets:/{t=1} t{print; if (index($0,"]")) exit}' \
  /path/to/MacOSX.sdk/usr/lib/libSystem.tbd | grep arm64-macos
```

Zig always resolves the SDK via `xcrun --sdk macosx --show-sdk-path`
internally and doesn't honor `SDKROOT`, so the script shims `xcrun` in
`PATH`. For a manual build, do the same:

```bash
mkdir -p fakebin
cat > fakebin/xcrun <<'EOF'
#!/bin/bash
if [[ "$*" == *"--sdk macosx --show-sdk-path"* ]]; then
    echo "$HOME/Library/SDKs/MacOSX15.5.sdk"
    exit 0
fi
exec /usr/bin/xcrun "$@"
EOF
chmod +x fakebin/xcrun
```

Prefix subsequent commands with `PATH="$(pwd)/fakebin:$PATH"`. Skip this
entirely if a plain `$ZIG build` links fine for you.

**4. Install the Metal Toolchain, if needed.**

Recent Xcode versions ship the Metal shader compiler as an optional
download. If the build fails with:

```
error: cannot execute tool 'metal' due to missing Metal Toolchain
```

run:

```bash
xcodebuild -downloadComponent MetalToolchain
```

**5. Build the xcframework (arm64-only, ReleaseFast).**

```bash
PATH="$(pwd)/fakebin:$PATH" "$ZIG" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native
```

- `-Dxcframework-target=native` builds an **arm64-only** framework. Argus is
  arm64-only (see `project.yml`'s `ARCHS` and `AGENTS.md` — single machine,
  not distributed), so this skips the x86_64 slice and the lipo/universal
  path entirely. Drop this flag to build a universal `macos-arm64_x86_64`
  slice instead (and point `project.yml` back at that slice path).
- `-Demit-macos-app=false` skips the full `Ghostty.app` bundle — that also
  links an x86_64 app binary, which can fail for reasons unrelated to the
  library (e.g. no Rosetta toolchain). We only need `libghostty`.
- `-Doptimize=ReleaseFast`, **not `Debug`**: a Debug build keeps Ghostty's
  internal `Page.verifyIntegrity()` consistency checks and a
  stack-trace-capturing safety allocator on the hot path — every line op
  (erase, scroll, attribute set) re-verifies and re-hashes the page. That's
  invisible for occasional keystrokes but pegs a CPU core at 100% on any
  surface receiving a steady stream of redraws (a TUI spinner, a busy build
  log), because the `io-reader` thread never catches up. On this (post-1.3.1)
  ghostty the exported C API survives `ReleaseFast` thanks to the
  `GHOSTTY_API` annotations. `Argus.app` itself can still be built in Debug —
  the xcframework is a separate compiled artifact, so you keep Swift-side
  debuggability. Only fall back to `Debug` here if you need to debug a crash
  inside Ghostty's own Zig code.

Output lands at `macos/GhosttyKit.xcframework`, with the combined static lib
at `macos-arm64/libghostty-internal-fat.a`.

**6. Vendor it.** (`scripts/build-ghosttykit.sh` does steps 1-6 for you,
pinned to a known-good `GHOSTTY_REF`/`ZIG_VERSION` — override those env vars
to bump the pinned version.)

Copy the built framework somewhere outside the repo and symlink it in.

```bash
CACHE_DIR="$HOME/.cache/argus/ghosttykit"
mkdir -p "$CACHE_DIR"
rm -rf "$CACHE_DIR/GhosttyKit.xcframework"
cp -R macos/GhosttyKit.xcframework "$CACHE_DIR/GhosttyKit.xcframework"

# project.yml links `-lghostty`, which expects `libghostty.a`. The combined
# archive is named `libghostty-internal.a` on current main (older main:
# `libghostty-internal-fat.a`); alias it:
macos_slice="$CACHE_DIR/GhosttyKit.xcframework/macos-arm64"
( cd "$macos_slice" && ln -sf libghostty-internal.a libghostty.a )

cd /path/to/argus
rm -f Frameworks/GhosttyKit.xcframework
ln -s "$CACHE_DIR/GhosttyKit.xcframework" Frameworks/GhosttyKit.xcframework
```

**7. Sanity-check the archive is complete**, so a silently-incomplete build
fails here instead of at Argus link time:

```bash
LIB="$CACHE_DIR/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a"
nm "$LIB" | grep " _ghostty_app_new$"       # core C API
nm "$LIB" | grep " _spvc_context_create$"   # a bundled dependency symbol
```

Both must print a `T`/`D` (defined) line. If either is only `U` (undefined)
or missing, the build is incomplete — you're almost certainly on `v1.3.1`
instead of `main` (see the note at the top).

### Keeping Argus's Swift code in sync with Ghostty's C API

Argus's `Argus/Ghostty/*.swift` wrappers are written against the pinned
`GHOSTTY_REF` above. They were originally adapted from a cmux fork of Ghostty
to vanilla upstream; those drifts are **already applied** and are noted here
only as reference for anyone bumping `GHOSTTY_REF`:

- `ghostty_surface_config_s` has no `io_mode` field upstream (the
  `GHOSTTY_SURFACE_IO_EXEC` assignment was removed in `TerminalSurface.swift`
  — leaving `command` unset already gets Ghostty to exec the default shell).

The bump from `88b4cd0` to `c959af6` reworked the clipboard C API; Argus's
adaptations live in `Argus/Ghostty/GhosttyClipboardCallbacks.swift`, modeled
on `macos/Sources/Ghostty/Ghostty.App.swift` in the Ghostty checkout:

- `ghostty_runtime_read_clipboard_cb` returns
  `ghostty_clipboard_read_result_e` and receives the requested MIME types
  plus a `list` flag.
- `ghostty_runtime_confirm_read_clipboard_cb` receives a borrowed
  `ghostty_clipboard_confirm_s`; its contents must be copied out
  synchronously because the confirmation completes asynchronously with
  exactly what the user approved.
- `ghostty_clipboard_content_s` carries an explicit `len`; `data` is
  binary-safe, not necessarily null-terminated.
- Denial completes via `ghostty_surface_deny_clipboard_request`, replacing
  the old "empty content + confirmed" workaround.

Bumping `GHOSTTY_REF` may surface new C API drifts as Swift compile errors.
Diff `macos-arm64/Headers/ghostty.h` in the built framework against the
previous one, and cross-reference the failing symbol against
`macos/Sources/Ghostty/Ghostty.App.swift` in the Ghostty checkout — that's
Ghostty's own reference Swift integration and shows the current expected
usage.
