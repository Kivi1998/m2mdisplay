import CGVirtualDisplayShim
import Foundation

final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    private let builtInDisplayID: CGDirectDisplayID
    private let ref: M2MVirtualDisplayRef

    init?(name: String, logicalWidth: Int, logicalHeight: Int, backingScale: Int, refreshRate: Double, widthMM: Int, heightMM: Int) {
        let pixelWidth = logicalWidth * backingScale
        let pixelHeight = logicalHeight * backingScale
        var displayID: UInt32 = 0
        guard let ref = name.withCString({ namePtr in
            M2MCreateVirtualDisplay(
                namePtr,
                UInt32(logicalWidth),
                UInt32(logicalHeight),
                UInt32(pixelWidth),
                UInt32(pixelHeight),
                refreshRate,
                UInt32(widthMM),
                UInt32(heightMM),
                &displayID
            )
        }) else {
            return nil
        }

        let initialMode = CGDisplayCopyDisplayMode(displayID)
        guard let builtInDisplayID = Self.builtInDisplayID(excluding: displayID) else {
            fputs("[VirtualDisplay] ERROR: 找不到 MacBook 内置显示器\n", stderr)
            M2MDestroyVirtualDisplay(ref)
            return nil
        }
        let builtInBounds = CGDisplayBounds(builtInDisplayID)
        let expectedVirtualOrigin = CGPoint(x: builtInBounds.width, y: 0)
        let needsModeChange = !Self.matches(
            initialMode,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        let needsUnmirror = CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
        let needsPlacement = CGDisplayBounds(builtInDisplayID).origin != .zero ||
            CGDisplayBounds(displayID).origin != expectedVirtualOrigin

        if needsModeChange || needsUnmirror || needsPlacement {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else {
                fputs("[VirtualDisplay] ERROR: couldn't begin display configuration\n", stderr)
                M2MDestroyVirtualDisplay(ref)
                return nil
            }
            if needsModeChange {
                // CGVirtualDisplay registers its custom mode with WindowServer
                // asynchronously after applySettings: returns. Querying
                // CGDisplayCopyAllDisplayModes immediately can race ahead of
                // that registration — confirmed reproducible when this
                // initializer runs from inside an already-running AppKit/
                // SwiftUI event loop (e.g. a MenuBarExtra button-tap handler),
                // but never from a plain command-line process calling this at
                // the top of a fresh run. Retry with a short wait rather than
                // failing on the first miss, matching the same "give
                // WindowServer a moment" pattern already used for capture
                // startup elsewhere in this codebase.
                var mode = Self.findMode(
                    displayID: displayID,
                    logicalWidth: logicalWidth,
                    logicalHeight: logicalHeight,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight
                )
                var findModeAttempts = 0
                while mode == nil && findModeAttempts < 5 {
                    findModeAttempts += 1
                    Thread.sleep(forTimeInterval: 0.1)
                    mode = Self.findMode(
                        displayID: displayID,
                        logicalWidth: logicalWidth,
                        logicalHeight: logicalHeight,
                        pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight
                    )
                }
                if let mode {
                    CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
                } else {
                    Self.logModes(displayID: displayID)
                    fputs("[VirtualDisplay] ERROR: couldn't find Retina mode after \(findModeAttempts) retries: looks like \(logicalWidth)x\(logicalHeight), backing pixels \(pixelWidth)x\(pixelHeight)\n", stderr)
                    CGCancelDisplayConfiguration(config)
                    M2MDestroyVirtualDisplay(ref)
                    return nil
                }
            }
            if needsUnmirror {
                CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
            }
            if needsPlacement {
                // 新建的 CGVirtualDisplay 会默认抢占 (0,0) 并成为主屏，把 MacBook
                // 内置屏推到负坐标。明确把内置屏固定为主屏、M2M 放到右侧，避免
                // 菜单栏和现有 App 窗口在开始投屏时自动跑到 iMac。
                CGConfigureDisplayOrigin(config, builtInDisplayID, 0, 0)
                CGConfigureDisplayOrigin(config, displayID, Int32(builtInBounds.width), 0)
            }
            let result = CGCompleteDisplayConfiguration(config, .forSession)
            if result != .success {
                fputs("[VirtualDisplay] ERROR: display configuration failed (CGCompleteDisplayConfiguration: \(result.rawValue))\n", stderr)
                M2MDestroyVirtualDisplay(ref)
                return nil
            }
        }

        guard let activeMode = CGDisplayCopyDisplayMode(displayID),
              activeMode.width == logicalWidth,
              activeMode.height == logicalHeight,
              activeMode.pixelWidth == pixelWidth,
              activeMode.pixelHeight == pixelHeight,
              CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay,
              CGDisplayIsMain(builtInDisplayID) != 0,
              CGDisplayBounds(displayID).origin == expectedVirtualOrigin else {
            let mode = CGDisplayCopyDisplayMode(displayID)
            fputs("[VirtualDisplay] ERROR: active mode is logical \(mode?.width ?? 0)x\(mode?.height ?? 0), pixels \(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0); expected logical \(logicalWidth)x\(logicalHeight), pixels \(pixelWidth)x\(pixelHeight)\n", stderr)
            M2MDestroyVirtualDisplay(ref)
            return nil
        }

        self.ref = ref
        self.displayID = displayID
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.builtInDisplayID = builtInDisplayID
        print("[VirtualDisplay] active Retina mode: looks like \(logicalWidth)x\(logicalHeight), backing pixels \(pixelWidth)x\(pixelHeight)")
    }

    /// 保持 MacBook 在左、M2M 虚拟屏在右，只切换谁位于全局坐标原点。
    /// macOS 把位于 (0,0) 的显示器视为主显示器，因此无需私有接口。
    func setMainDisplay(receiverIsMain: Bool) -> Bool {
        let origins = Self.displayOrigins(
            builtInWidth: Int32(CGDisplayBounds(builtInDisplayID).width.rounded()),
            receiverIsMain: receiverIsMain
        )
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }

        CGConfigureDisplayOrigin(config, builtInDisplayID, origins.builtInX, 0)
        CGConfigureDisplayOrigin(config, displayID, origins.virtualX, 0)

        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { return false }
        let expectedMain = receiverIsMain ? displayID : builtInDisplayID
        return CGDisplayIsMain(expectedMain) != 0 &&
            CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay
    }

    static func displayOrigins(
        builtInWidth: Int32,
        receiverIsMain: Bool
    ) -> (builtInX: Int32, virtualX: Int32) {
        receiverIsMain ? (-builtInWidth, 0) : (0, builtInWidth)
    }

    private static func builtInDisplayID(excluding excludedID: CGDirectDisplayID) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first {
            $0 != excludedID && CGDisplayIsBuiltin($0) != 0
        }
    }

    private static func findMode(
        displayID: CGDirectDisplayID,
        logicalWidth: Int,
        logicalHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return nil }
        return modes.first { mode in
            matches(
                mode,
                logicalWidth: logicalWidth,
                logicalHeight: logicalHeight,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }
    }

    private static func matches(
        _ mode: CGDisplayMode?,
        logicalWidth: Int,
        logicalHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Bool {
        guard let mode else { return false }
        return mode.width == logicalWidth &&
            mode.height == logicalHeight &&
            mode.pixelWidth == pixelWidth &&
            mode.pixelHeight == pixelHeight
    }

    private static func logModes(displayID: CGDirectDisplayID) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }
        for mode in modes {
            fputs("[VirtualDisplay] available mode: logical \(mode.width)x\(mode.height), pixels \(mode.pixelWidth)x\(mode.pixelHeight), \(mode.refreshRate)Hz, flags=\(mode.ioFlags)\n", stderr)
        }
    }

    deinit {
        M2MDestroyVirtualDisplay(ref)
    }
}
