import AppKit
import CoreGraphics
import Darwin
import ObjectiveC.runtime

/// 调用 Control Center 自己使用的原生音量 HUD。
///
/// 苹果没有公开音量 HUD API；当前系统的入口位于 OSD 私有框架。这里不静态链接
/// 私有符号，而是在运行时确认类、选择器和方法签名都存在后再调用。系统升级导致
/// 入口失效时会返回 `false`，由接收端回退到自绘提示条，不影响真实音量调节。
final class NativeVolumeHUD {
    struct Presentation: Equatable {
        let imageID: Int64
        let filledChiclets: UInt32
    }

    private typealias SharedManagerFunction = @convention(c) (AnyObject, Selector) -> AnyObject
    private typealias ShowImageFunction = @convention(c) (
        AnyObject,
        Selector,
        Int64,
        UInt32,
        UInt32,
        UInt32,
        UInt32,
        UInt32,
        Bool
    ) -> Void

    private static let frameworkPath = "/System/Library/PrivateFrameworks/OSD.framework/OSD"
    private static let sharedManagerSelector = NSSelectorFromString("sharedManager")
    private static let showImageSelector = NSSelectorFromString(
        "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
    )

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let manager: AnyObject?
    private let showImageFunction: ShowImageFunction?

    init() {
        frameworkHandle = dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_LOCAL)

        guard frameworkHandle != nil,
              let managerClass = NSClassFromString("OSDManager"),
              let managerMetaClass = object_getClass(managerClass),
              class_respondsToSelector(managerMetaClass, Self.sharedManagerSelector),
              class_respondsToSelector(managerClass, Self.showImageSelector),
              let sharedManagerImplementation = class_getMethodImplementation(
                  managerMetaClass,
                  Self.sharedManagerSelector
              ),
              let showImageImplementation = class_getMethodImplementation(
                  managerClass,
                  Self.showImageSelector
              ) else {
            manager = nil
            showImageFunction = nil
            return
        }

        let sharedManagerFunction = unsafeBitCast(
            sharedManagerImplementation,
            to: SharedManagerFunction.self
        )
        manager = sharedManagerFunction(managerClass, Self.sharedManagerSelector)
        showImageFunction = unsafeBitCast(
            showImageImplementation,
            to: ShowImageFunction.self
        )
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    var isAvailable: Bool {
        manager != nil && showImageFunction != nil
    }

    @discardableResult
    func show(volume: Float, muted: Bool, displayID: CGDirectDisplayID) -> Bool {
        guard let manager, let showImageFunction else { return false }
        let presentation = Self.presentation(volume: volume, muted: muted)

        showImageFunction(
            manager,
            Self.showImageSelector,
            presentation.imageID,
            displayID,
            500,
            1_000,
            presentation.filledChiclets,
            100,
            false
        )
        return true
    }

    static func presentation(volume: Float, muted: Bool) -> Presentation {
        let clampedVolume = max(0, min(1, volume))
        return Presentation(
            imageID: muted ? 4 : 3,
            filledChiclets: muted ? 0 : UInt32((clampedVolume * 100).rounded())
        )
    }
}
