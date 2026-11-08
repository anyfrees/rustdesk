#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <bcrypt.h>
#include <limits.h>

/* Keep ProcessPrng's exact ABI; use the documented system CSPRNG on Win7. */
__declspec(dllexport) BOOL WINAPI ProcessPrng(PBYTE output, SIZE_T requested) {
    if (!output && requested) return FALSE;
    while (requested) {
        ULONG count = requested > ULONG_MAX ? ULONG_MAX : (ULONG)requested;
        NTSTATUS status = BCryptGenRandom(NULL, output, count,
                                         BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        if (!BCRYPT_SUCCESS(status)) return FALSE;
        output += count;
        requested -= count;
    }
    return TRUE;
}
