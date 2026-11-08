#pragma once

#include <windows.h>
#include <mmsystem.h>
#include <cmath>
#include <algorithm>
#include <cstdint>
#include <vector>

#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "advapi32.lib")

namespace nnu {
constexpr wchar_t kVoiceSoundKey[] = L"Software\\RustDesk\\NNU\\VoiceCalls";

inline bool VoiceSoundEnabled() {
  DWORD enabled = 1, size = sizeof(enabled);
  return RegGetValueW(HKEY_CURRENT_USER, kVoiceSoundKey, L"Sound",
                     RRF_RT_REG_DWORD, nullptr, &enabled, &size) != ERROR_SUCCESS || enabled != 0;
}

inline LSTATUS SetVoiceSoundEnabled(bool enabled) {
  const DWORD value = enabled ? 1 : 0;
  return RegSetKeyValueW(HKEY_CURRENT_USER, kVoiceSoundKey, L"Sound",
                        REG_DWORD, &value, sizeof(value));
}

inline std::vector<BYTE> MakeVoiceTone(int mode) {
  constexpr int rate = 22050;
  const int count = mode == 1 ? rate * 6 / 5 : rate;
  std::vector<BYTE> wave;
  wave.reserve(44 + count * 2);
  auto word = [&](uint32_t value, int bytes) {
    for (int i = 0; i < bytes; ++i) wave.push_back(static_cast<BYTE>(value >> (i * 8)));
  };
  auto text = [&](const char* value) { for (int i = 0; i < 4; ++i) wave.push_back(value[i]); };
  text("RIFF"); word(36 + count * 2, 4); text("WAVE"); text("fmt ");
  word(16, 4); word(1, 2); word(1, 2); word(rate, 4); word(rate * 2, 4);
  word(2, 2); word(16, 2); text("data"); word(count * 2, 4);
  constexpr double tau = 6.283185307179586;
  for (int i = 0; i < count; ++i) {
    const double t = static_cast<double>(i) / rate;
    double sample = 0;
    if (mode == 1) {
      for (int note = 0; note < 2; ++note) {
        const double elapsed = t - note * .4;
        if (elapsed < 0 || elapsed > .65) continue;
        const double frequency = note == 0 ? 660 : 880;
        const double attack = (std::min)(1., elapsed / .012);
        const double envelope = attack * std::exp(-7 * elapsed);
        sample += envelope * (std::sin(tau * frequency * elapsed) +
                               .15 * std::sin(tau * frequency * 2 * elapsed));
      }
    } else if (t < .85) {
      const double envelope = (std::min)({1., t / .02, (.85 - t) / .02});
      sample = .5 * envelope * (std::sin(tau * 440 * t) + std::sin(tau * 480 * t));
    }
    const auto pcm = static_cast<int16_t>((std::max)(-1., (std::min)(1., sample * .27)) * 32767);
    word(static_cast<uint16_t>(pcm), 2);
  }
  return wave;
}

inline bool& VoiceTonePlaying() { static bool playing = false; return playing; }

inline void StopVoiceTone() {
  if (VoiceTonePlaying()) {
    PlaySoundW(nullptr, nullptr, 0);
    VoiceTonePlaying() = false;
  }
}

inline bool PlayVoiceTone(int mode) {
  const bool enabled = VoiceSoundEnabled();
  if (mode == 0 || !enabled) { StopVoiceTone(); return enabled; }
  static const auto incoming = MakeVoiceTone(1);
  static const auto outgoing = MakeVoiceTone(2);
  const auto& wave = mode == 1 ? incoming : outgoing;
  VoiceTonePlaying() = PlaySoundW(reinterpret_cast<LPCWSTR>(wave.data()), nullptr,
                                  SND_MEMORY | SND_ASYNC | SND_NODEFAULT) != FALSE;
  return enabled;
}
}  // namespace nnu
