import AppKit
import ApplicationServices
import CoreGraphics

/// `OSDManager` 的旧式入口会把音量 HUD 固定在屏幕右上方，而不是使用菜单栏
/// “声音”图标作为锚点。这里在 Control Center 创建 HUD 后读取两个原生元素的
/// 实际坐标，只修正 HUD 窗口的横坐标，内容、尺寸、材质和动画仍完全由系统负责。
final class ControlCenterHUDPositioner {
    private static let controlCenterBundleIdentifier = "com.apple.controlcenter"
    private static let soundDescriptions = ["声音", "Sound"]
    private static let retryDelays: [TimeInterval] = [0.02, 0.06, 0.12]

    private var generation = 0

    func centerNextHUD(completion: @escaping (String) -> Void) {
        generation &+= 1
        let currentGeneration = generation

        for (index, delay) in Self.retryDelays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                switch self.centerCurrentHUD() {
                case .success(let message):
                    self.generation &+= 1
                    completion(message)
                case .failure(let error):
                    if index == Self.retryDelays.count - 1 {
                        completion(error.message)
                    }
                }
            }
        }
    }

    static func centeredOriginX(anchorRect: CGRect, hudBounds: CGRect) -> CGFloat {
        (anchorRect.midX - hudBounds.width / 2).rounded()
    }

    private func centerCurrentHUD() -> Result<String, PositioningError> {
        guard AXIsProcessTrusted() else {
            return .failure(.message("辅助功能权限不可用，无法读取菜单栏声音图标"))
        }
        guard let controlCenter = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.controlCenterBundleIdentifier
        ).first else {
            return .failure(.message("找不到 Control Center 进程"))
        }

        let applicationElement = AXUIElementCreateApplication(controlCenter.processIdentifier)
        guard let soundRect = soundMenuItemRect(in: applicationElement) else {
            return .failure(.message("菜单栏没有可见的声音图标"))
        }
        guard let hudBounds = nativeHUDBounds(ownerPID: controlCenter.processIdentifier) else {
            return .failure(.message("尚未找到 Control Center 音量 HUD 窗口"))
        }
        guard let hudWindow = accessibilityWindow(at: hudBounds) else {
            return .failure(.message("无法取得 Control Center HUD 的辅助功能窗口"))
        }

        var isPositionSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            hudWindow,
            kAXPositionAttribute as CFString,
            &isPositionSettable
        ) == .success,
              isPositionSettable.boolValue else {
            return .failure(.message("Control Center 不允许移动 HUD 窗口"))
        }

        var targetOrigin = CGPoint(
            x: Self.centeredOriginX(anchorRect: soundRect, hudBounds: hudBounds),
            y: hudBounds.minY
        )
        guard let targetValue = AXValueCreate(.cgPoint, &targetOrigin) else {
            return .failure(.message("无法创建 HUD 目标坐标"))
        }
        let result = AXUIElementSetAttributeValue(
            hudWindow,
            kAXPositionAttribute as CFString,
            targetValue
        )
        guard result == .success else {
            return .failure(.message("移动 Control Center HUD 失败：\(result.rawValue)"))
        }

        return .success(
            "原生音量 HUD 已居中到声音图标：图标中心=\(Int(soundRect.midX))，" +
            "窗口横坐标=\(Int(targetOrigin.x))"
        )
    }

    private func soundMenuItemRect(in applicationElement: AXUIElement) -> CGRect? {
        guard let menuBar: AXUIElement = copyAttribute(kAXMenuBarAttribute, from: applicationElement),
              let items: [AXUIElement] = copyAttribute(kAXChildrenAttribute, from: menuBar) else {
            return nil
        }

        for item in items {
            guard let description: String = copyAttribute(kAXDescriptionAttribute, from: item),
                  Self.soundDescriptions.contains(description),
                  let position = point(attribute: kAXPositionAttribute, from: item),
                  let size = size(attribute: kAXSizeAttribute, from: item) else {
                continue
            }
            return CGRect(origin: position, size: size)
        }
        return nil
    }

    private func nativeHUDBounds(ownerPID: pid_t) -> CGRect? {
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return windowInfo.compactMap { item -> (layer: Int, bounds: CGRect)? in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
                  let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer > ReceiverEngine.cursorWindowLevel.rawValue,
                  let boundsDictionary = item[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 200,
                  bounds.width < 600,
                  bounds.height > 60,
                  bounds.height < 260 else {
                return nil
            }
            return (layer, bounds)
        }
        .max { $0.layer < $1.layer }?
        .bounds
    }

    private func accessibilityWindow(at bounds: CGRect) -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(bounds.midX),
            Float(bounds.midY),
            &hitElement
        ) == .success,
              let hitElement else {
            return nil
        }

        if let window: AXUIElement = copyAttribute(kAXWindowAttribute, from: hitElement) {
            return window
        }

        var currentElement = hitElement
        for _ in 0..<8 {
            let role: String? = copyAttribute(kAXRoleAttribute, from: currentElement)
            if role == kAXWindowRole as String {
                return currentElement
            }
            guard let parent: AXUIElement = copyAttribute(kAXParentAttribute, from: currentElement) else {
                break
            }
            currentElement = parent
        }
        return nil
    }

    private func point(attribute: String, from element: AXUIElement) -> CGPoint? {
        guard let value: AXValue = copyAttribute(attribute, from: element),
              AXValueGetType(value) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func size(attribute: String, from element: AXUIElement) -> CGSize? {
        guard let value: AXValue = copyAttribute(attribute, from: element),
              AXValueGetType(value) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private func copyAttribute<T>(_ attribute: String, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }
}

private enum PositioningError: Error {
    case message(String)

    var message: String {
        switch self {
        case .message(let message): message
        }
    }
}
