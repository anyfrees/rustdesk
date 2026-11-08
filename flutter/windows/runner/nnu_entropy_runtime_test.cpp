#include "nnu_entropy_runtime.h"
#include <cassert>
#include <cstring>

int wmain(int argc, wchar_t**) {
  SetErrorMode(SEM_NOGPFAULTERRORBOX);
  wchar_t executable[32768];
  GetModuleFileNameW(nullptr, executable, 32768);
  std::wstring engine_path(executable);
  engine_path.resize(engine_path.find_last_of(L"\\/") + 1);
  engine_path += L"flutter_windows.dll";
  const auto engine = LoadLibraryExW(engine_path.c_str(), nullptr,
                                    LOAD_WITH_ALTERED_SEARCH_PATH);
  assert(engine);
  assert(SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32 |
                                 LOAD_LIBRARY_SEARCH_USER_DIRS));
  assert(SetDllDirectoryW(L""));
  assert(!LoadLibraryW(L"nnu_win7_rng.dll"));
  if (argc == 1) assert(NnuLoadEntropyRuntime());
  using Random = int (*)(unsigned char*, size_t);
  const auto random = reinterpret_cast<Random>(
      reinterpret_cast<unsigned char*>(engine) + 0x4b2c1a);
  unsigned char first[256] = {}, second[256] = {};
  assert(random(first, sizeof(first)) == 1);
  assert(random(second, sizeof(second)) == 1);
  assert(memcmp(first, second, sizeof(first)) != 0);
  assert(GetModuleHandleW(L"nnu_win7_rng.dll"));
  // The fix must not widen the process DLL search policy.
  assert(!LoadLibraryW(L"nnu_entropy_untrusted.dll"));
  return 0;
}
