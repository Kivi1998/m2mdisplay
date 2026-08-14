#ifndef CGVirtualDisplayShim_h
#define CGVirtualDisplayShim_h

#include <stdint.h>
#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 指向活动 CGVirtualDisplay 的不透明持有句柄。
/// 显示器需要存在多久，就必须持有多久；调用 M2MDestroyVirtualDisplay 释放后，
/// 虚拟显示器会被销毁。
typedef void *M2MVirtualDisplayRef;

/// 创建并激活虚拟显示器，失败时返回 NULL。
/// logicalWidth/logicalHeight 控制可见桌面尺寸。
/// maxPixelWidth/maxPixelHeight 控制 Retina 后备像素上限。
/// 此适配层会启用 HiDPI，因此可使用 3840×2160 后备缓冲绘制 1920×1080 逻辑点，
/// 而不会缩小文字或窗口。
/// widthMM/heightMM 是 CoreGraphics 报告的物理尺寸，会影响默认点缩放；
/// refreshRate 的单位为赫兹。displayIDOut 接收 ScreenCaptureKit 和
/// system_profiler 可识别的 CGDirectDisplayID。
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

#endif /* CGVirtualDisplayShim_h 结束 */
