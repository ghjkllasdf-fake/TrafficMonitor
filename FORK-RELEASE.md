# TrafficMonitor 1.86.1 — unofficial fork

This is a fork of [TrafficMonitor by zhongyang219 and contributors](https://github.com/zhongyang219/TrafficMonitor), not an official upstream release. Original copyright, acknowledgements and licenses remain unchanged.

## Scope and attribution

- Baseline: `930f17533d6098989ebad62f210aa97d75ef174b` in `ghjkllasdf-fake/TrafficMonitor`.
- Windows 11 left/right taskbar fix: **chuckie / bighamx**, original commit `912642621527904b179ca228c54d9ea9723c39e8`, tag [`V1.86-win11-side.1`](https://github.com/bighamx/TrafficMonitor/releases/tag/V1.86-win11-side.1), [upstream PR #2421](https://github.com/zhongyang219/TrafficMonitor/pull/2421).
- All four patched C++ files are identical to that commit. No bold-label feature or other functional changes were added.
- Application version: 1.86.1; Windows file/product version: 1.86.1.0. Existing upstream update feeds are deliberately not rewritten to advertise an unpublished fork release.

## Portable distribution

As with upstream V1.86, distribution is an extract-and-run ZIP, not MSI. Extract to a new writable folder and run `TrafficMonitor.exe`. Do not overlay a running installation. No user configuration, history, logs, installed plugins or credentials are included.

`_Lite.zip` is explicitly the upstream Lite edition: it does **not** include hardware temperature monitoring. Do not mistake it for the full edition. Full-edition packaging rebuilds LibreHardwareMonitor 0.9.4 and HidSharp 2.1.0 from pinned source commits without debug paths, plus the C++/CLI bridge from this checkout; each binary must pass the privacy gate. The upstream dependency and official bridge embed PDB build paths and are never copied into the release. Dependency licenses and revision provenance are included. Full supports x64/x86 and requires .NET Framework 4.7.2+ and the Microsoft Visual C++ v143 runtime; ARM64EC is Lite only.

The package includes the compiled application, tracked translations/skins, licenses, this notice and commit/hash provenance. Cosmetic shortcuts and Start-menu logo files from the official binary archive are not copied. MSVC/MFC runtime is linked statically for the Lite build. No Microsoft installer or signing certificate is fabricated.

## Clean build and verification

Requirements: Windows, Node.js 22+, Git, Visual Studio 2022 C++ v143 tools, MFC/ATL and Windows SDK. The full edition additionally requires C++/CLI and .NET Framework 4.7.2 targeting support. No tool installation or elevation is performed by the scripts.

From a clean committed checkout:

```powershell
node build/audit.mjs self-test
node build/audit.mjs source
powershell -NoProfile -File build/build-release.ps1 -Architecture x64 -Edition Lite
```

Other supported project platforms: `x86`, `ARM64EC`. Use the `Fork release CI` workflow for isolated hosted builds. `dist` holds only verified ZIPs and SHA-256 files. Build intermediates stay within the checkout. Per-user MSBuild property imports are redirected to an empty local directory.

Static MFC carries vendor source paths in precompiled diagnostic strings. A narrowly scoped post-link step replaces only MFC/ATL source filenames in non-executable data sections with same-length neutral labels, rejects signed inputs, and does not alter executable code or offsets. The final bytes are then audited and hashed. The build suppresses compiler/linker debug information, uses `/Brepro` and `/pathmap`, records the source commit time instead of the wall clock, and checks real PE bytes for PDB references, absolute paths and debug records. ZIP order/timestamps are stable; the packager reopens the actual archive and verifies the exact allowlist and every member hash. This is reproducible build support, **not** a claim of proven bit-identical builds across changing hosted runner/MSVC versions. Pin the toolchain and compare independent builds before making that stronger claim.

The source audit covers tracked and nonignored candidate files, UTF-8/UTF-16 secret patterns, private home paths and sensitive filenames. It prints rule IDs and relative filenames only. This is heuristic screening, not a guarantee that arbitrary secrets or all PII are detectable; public upstream author/contributor credits remain intact.

## Publication policy

Only `ghjkllasdf-fake/TrafficMonitor` may receive the feature branch, PR, tag or release. Do not force-push, merge the PR automatically, or open an upstream PR. Publishing uses the tested feature commit, not an untested merge. A successful build workflow produces artifacts; it does not itself assert runtime validation.

Before publication, review Windows 11 left/right/top/bottom taskbars, narrow/wide widths, monitor changes, DPI changes and Explorer restarts on the built version. The original patch was user-verified; a new 1.86.1 build must not inherit an unperformed runtime-test claim.
