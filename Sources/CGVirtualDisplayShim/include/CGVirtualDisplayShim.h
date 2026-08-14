#ifndef CGVirtualDisplayShim_h
#define CGVirtualDisplayShim_h

#include <stdint.h>
#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque, retained handle to a live CGVirtualDisplay. Keep it alive for as long
/// as the display should exist; releasing it (M2MDestroyVirtualDisplay) tears
/// the display down.
typedef void *M2MVirtualDisplayRef;

/// Creates and activates a virtual display. Returns NULL on failure.
/// logicalWidth/logicalHeight control the visible desktop size.
/// maxPixelWidth/maxPixelHeight control the Retina backing-pixel ceiling. The
/// shim enables HiDPI, so 1920x1080 logical points can be drawn with a
/// 3840x2160 backing store without shrinking text or windows.
/// widthMM/heightMM are the physical size CoreGraphics reports (affects default
/// point scaling), refreshRate in Hz. displayIDOut receives the CGDirectDisplayID
/// that ScreenCaptureKit / system_profiler will see.
M2MVirtualDisplayRef M2MCreateVirtualDisplay(const char *name,
                                              uint32_t logicalWidth,
                                              uint32_t logicalHeight,
                                              uint32_t maxPixelWidth,
                                              uint32_t maxPixelHeight,
                                              double refreshRate,
                                              uint32_t widthMM,
                                              uint32_t heightMM,
                                              uint32_t *displayIDOut);

void M2MDestroyVirtualDisplay(M2MVirtualDisplayRef ref);

#ifdef __cplusplus
}
#endif

#endif /* CGVirtualDisplayShim_h */
