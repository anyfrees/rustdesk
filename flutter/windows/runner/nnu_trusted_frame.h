#ifndef RUNNER_NNU_TRUSTED_FRAME_H_
#define RUNNER_NNU_TRUSTED_FRAME_H_

#include <windows.h>
#include <dwmapi.h>
#include <algorithm>
#include <cmath>

namespace nnu {

inline bool NeedsLegacyTransparency() {
  using Version = LONG(WINAPI*)(OSVERSIONINFOW*);
  auto version = reinterpret_cast<Version>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
  OSVERSIONINFOW info = {};
  info.dwOSVersionInfoSize = sizeof(info);
  return version && version(&info) == 0 && info.dwMajorVersion == 6 &&
         info.dwMinorVersion <= 1;
}

inline HRGN TrustedContentRegion(int mode, int width, int height, double scale,
                                 double message_height = 76) {
  auto pixel = [scale](double value) {
    return static_cast<int>(std::lround(value * scale));
  };
  if (mode == 4 || mode == 5) {
    const bool left = mode == 4;
    const int center = height / 2;
    const int body_left = left ? pixel(4) : pixel(98);
    const int body_right = left ? width - pixel(98) : width - pixel(4);
    const int bubble_height = std::min(height, pixel(message_height));
    const int bubble_top = (height - bubble_height) / 2;
    HRGN region = CreateRoundRectRgn(body_left, bubble_top, body_right + 1,
                                    bubble_top + bubble_height + 1, pixel(32), pixel(32));
    const int base = left ? body_right - 1 : body_left + 1;
    const int tip = left ? body_right + pixel(8) : body_left - pixel(8);
    POINT points[] = {{base, center - pixel(7)}, {tip, center},
                       {base, center + pixel(7)}};
    HRGN tail = CreatePolygonRgn(points, 3, WINDING);
    const int avatar = left ? width - pixel(43) : pixel(43);
    const int radius = pixel(NeedsLegacyTransparency() ? 26 : 43);
    HRGN circle = CreateEllipticRgn(avatar - radius, center - radius,
                                   avatar + radius, center + radius);
    if (!region || !tail || !circle) {
      if (region) DeleteObject(region);
      if (tail) DeleteObject(tail);
      if (circle) DeleteObject(circle);
      return nullptr;
    }
    CombineRgn(region, region, tail, RGN_OR);
    CombineRgn(region, region, circle, RGN_OR);
    DeleteObject(tail);
    DeleteObject(circle);
    return region;
  }
  if (mode == 2) {
    const int radius = std::min({pixel(NeedsLegacyTransparency() ? 26 : 43),
                                 width / 2, height / 2});
    return CreateEllipticRgn(width / 2 - radius, height / 2 - radius,
                             width / 2 + radius, height / 2 + radius);
  }
  const int inset = std::min({pixel(mode == 6 && NeedsLegacyTransparency() ? 22 :
                                   mode == 1 || mode == 6 ? 16 : 4),
                              std::max(0, (width - 1) / 2),
                              std::max(0, (height - 1) / 2)});
  const int diameter = mode == 6 ? std::max(1, height - inset * 2)
                                 : pixel(mode == 1 ? 48 : 42);
  return CreateRoundRectRgn(inset, inset, width - inset + 1,
                            height - inset + 1, diameter, diameter);
}

class TrustedFrame {
 public:
  void SetMessage(HWND window, int mode, double height) {
    message_height_ = height;
    SetMode(window, mode);
  }

  void SetMode(HWND window, int mode) {
    if (!NeedsLegacyTransparency() && mode != 2 && mode != 4 && mode != 5 && mode != 6) {
      if (clipped_) SetWindowRgn(window, nullptr, TRUE);
      mode_ = 0;
      clipped_ = false;
      return;
    }
    mode_ = mode;
    Refresh(window);
  }

  void Reset(HWND window) {
    if (!NeedsLegacyTransparency()) {
      if (clipped_) SetWindowRgn(window, nullptr, TRUE);
      mode_ = 0;
      clipped_ = false;
      return;
    }
    mode_ = 0;
    DWM_BLURBEHIND blur = {};
    blur.dwFlags = DWM_BB_ENABLE;
    DwmEnableBlurBehindWindow(window, &blur);
    if (clipped_) SetWindowRgn(window, nullptr, TRUE);
    clipped_ = false;
  }

  void Refresh(HWND window) {
    if (!mode_ || updating_) return;
    RECT area;
    if (!GetClientRect(window, &area) || area.right <= 0 || area.bottom <= 0)
      return;
    HDC dc = GetDC(window);
    double scale = dc ? GetDeviceCaps(dc, LOGPIXELSX) / 96.0 : 1.0;
    if (dc) ReleaseDC(window, dc);
    {
      using Dpi = UINT(WINAPI*)(HWND);
      auto dpi = reinterpret_cast<Dpi>(GetProcAddress(
          GetModuleHandleW(L"user32.dll"), "GetDpiForWindow"));
      if (dpi) {
        const UINT value = dpi(window);
        if (value) scale = value / 96.0;
      }
    }
    HRGN region = TrustedContentRegion(mode_, area.right, area.bottom, scale,
                                       message_height_);
    if (!region) return;
    updating_ = true;
    BOOL composition = FALSE;
    bool glass = false;
    if (NeedsLegacyTransparency() &&
        SUCCEEDED(DwmIsCompositionEnabled(&composition)) && composition) {
      DWM_BLURBEHIND blur = {};
      blur.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
      blur.fEnable = TRUE;
      blur.hRgnBlur = region;
      glass = SUCCEEDED(DwmEnableBlurBehindWindow(window, &blur));
    }
    if (glass) {
      if (clipped_) SetWindowRgn(window, nullptr, TRUE);
      clipped_ = false;
    } else if (SetWindowRgn(window, region, TRUE)) {
      // Windows owns the region after a successful SetWindowRgn.
      region = nullptr;
      clipped_ = true;
    }
    if (region) DeleteObject(region);
    updating_ = false;
  }

 private:
  int mode_ = 0;
  double message_height_ = 76;
  bool clipped_ = false;
  bool updating_ = false;
};

}  // namespace nnu
#endif
