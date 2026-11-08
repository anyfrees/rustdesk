# Win7 x64 BoringSSL entropy compatibility

The supplied Flutter 3.24.5 engine calls `abort` when its BoringSSL
`init_processprng` cannot resolve `ProcessPrng` in Windows 7's system
`bcryptprimitives.dll`. A user crash dump identifies this exact path during
`SSL_new` / `RAND_bytes`.

This adapter exports the exact `BOOL WINAPI ProcessPrng(PBYTE, SIZE_T)` ABI,
using Microsoft's documented `BCryptGenRandom(NULL, ..., BCRYPT_USE_SYSTEM_PREFERRED_RNG)`.
Large requests are split at the API's `ULONG` limit. Any system RNG failure
returns FALSE, preserving BoringSSL's fail-closed behavior. It does not change
certificate verification, TLS parameters, entropy strength or system DLLs.

Build `build.cmd` in an x64 Visual Studio developer prompt. No CRT is linked.
Run `py patch_engine.py original/flutter_windows.dll client/flutter_windows.dll`
and place `nnu_win7_rng.dll` beside the client EXE. The patch is gated by the
original engine's full SHA256. It replaces only one UTF-16 DLL name at the
verified RVA, preserving executable code, unwind metadata, relocations and
all other bytes. The original upstream engine is never modified in place.
UI21.14 distribution builds use the same verified adapter and patched copy
on Windows 7/10/11, so the shared automatic update channel cannot replace
a working Windows 7 runtime with an incompatible entropy loader.
Unknown engines are rejected.

UI21.15's Windows runner loads the adapter from the EXE's absolute directory
before starting Flutter. The core's Windows 10+ safe DLL search policy excludes
the application directory, so relying on BoringSSL's later name-only load
causes an abort despite the adapter being present. The explicit load retains
that policy; adapter dependencies are restricted to System32 when the OS
supports that flag. Unpatched Win7 uses the absolute path with its original
loader. Keep the module loaded until process exit. The native regression test
uses the actual patched engine under the core's restricted search policy,
from an unrelated working directory.

The official engine source/build is maintained at
https://github.com/rustdesk/engine . This is a narrowly scoped distribution
patch, not a claim that the entire engine was rebuilt from source here.

API reference:
https://learn.microsoft.com/en-us/windows/win32/api/bcrypt/nf-bcrypt-bcryptgenrandom

Client changes retain the project's AGPL-3.0 licensing. This directory and
the reproducible patch record are shipped with the Win7 x64 package.
