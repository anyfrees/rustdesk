#pragma once

#include <windows.h>
#include <string>

inline bool NnuLoadEntropyRuntime() {
  wchar_t executable[32768];
  const DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
  if (length == 0 || length >= 32768) return false;
  std::wstring path(executable, length);
  const auto separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return false;
  path.resize(separator + 1);
  path += L"nnu_win7_rng.dll";

  // The core excludes the application directory from subsequent DLL searches.
  // Keep that policy and pin only the packaged entropy adapter by absolute path.
  const auto kernel = GetModuleHandleW(L"kernel32.dll");
  const DWORD flags = GetProcAddress(kernel, "SetDefaultDllDirectories")
                          ? LOAD_LIBRARY_SEARCH_SYSTEM32 : 0;
  const auto module = LoadLibraryExW(path.c_str(), nullptr, flags);
  if (!module) return false;
  if (!GetProcAddress(module, "ProcessPrng")) {
    FreeLibrary(module);
    SetLastError(ERROR_PROC_NOT_FOUND);
    return false;
  }
  // BoringSSL resolves the loaded module by name later; retain it until exit.
  return true;
}
