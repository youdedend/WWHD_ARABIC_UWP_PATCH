# WWHD Arabic UWP Patch

This repository applies the supplied Arabic-script joining fix to [JYRS20/WWHD-UWP `v0.1.4`](https://github.com/JYRS20/WWHD-UWP/releases/tag/v0.1.4) and builds a downloadable, signed x64 UWP package.

## Patch contents

- `patch/runtime/src/rtl_text.cpp`: expanded Arabic Presentation Forms-A joining mappings.
- `patch/runtime/tools/rtl_text_test.cpp`: regression coverage for the new mappings and joined peh shaping.
- `ARABIC_FIX_NOTES.md`: notes and font/in-game validation limitations supplied with the fix.

The source build combines [ZeldaWWHDRecomp commit `f10b56621ed13e0053e7cf8190e740834377e45a`](https://github.com/ZeldaWWHDRecomp/ZeldaWWHDRecomp/commit/f10b56621ed13e0053e7cf8190e740834377e45a) with the `v0.1.4` UWP source overlay, then applies these patch files. No game images, keys, saves, or generated game code are included.

## Build

`scripts/Build-ArabicUwp.ps1` performs the complete build on a Windows machine with Visual Studio C++ tools, LLVM/Clang, CMake, Ninja, Git, and the Windows SDK:

```powershell
pwsh -NoLogo -NoProfile -File scripts/Build-ArabicUwp.ps1
```

The script:

1. Downloads and checksum-verifies the original `v0.1.4` release and pinned public source dependencies.
2. Applies the Arabic source patch and runs its RTL regression test.
3. Compiles a new `wwhd-uwp-game.exe` with Clang for WindowsStore/UWP. Unchanged runtime DLLs and assets are retained from the verified original APPX; import libraries are generated from their exports.
4. Updates the APPX version to `0.1.4.1`, repacks it with MakeAppx, signs it with a new self-signed certificate, and verifies the signature with SignTool.
5. Produces `dist/wwhd-uwp-0.1.4-arabic-fix-x64.zip`, including the APPX, certificate, VCLibs dependency, installation notes, provenance, and SHA-256 checksums.

The GitHub Actions workflow runs the same script on `windows-latest`. A manually dispatched run with **publish** enabled also creates the public release.

## Validation scope

The standalone Arabic shaping test, native compilation, APPX packaging, and signature verification are automated. Xbox/in-game rendering still requires device validation, and the active game font must contain the contextual Arabic glyphs.
