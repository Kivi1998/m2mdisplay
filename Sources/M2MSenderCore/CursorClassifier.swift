import AppKit
import M2MShared

/// 把 `NSCursor.currentSystem`（跨进程读取的系统级当前光标，不同于只反映本 App
/// 光标矩形的 `NSCursor.current`）归类成 `CursorType`。
///
/// 不能用 `=== NSCursor.iBeam` 之类的单例身份比较：实测在这个项目的进程环境
/// 下，`NSCursor.arrow`/`.iBeam` 这两个静态单例的 `.image` 读出来是空图像
/// （0 张 representation），显然不是 WindowServer 实际用来渲染的那份资源，
/// `currentSystem` 返回的对象也不会跟它们身份相同。改用位图尺寸 + 热点坐标
/// 做指纹匹配——这两个值来自 `currentSystem` 直接读到的真实位图，在同一台
/// 机器、同一个系统版本下测出来是稳定的：
///   箭头 28×40 热点(5,5)，手形 32×32 热点(13,8)，工字 23×22 热点(12,11)。
/// 换了系统版本这组数字可能会变，指纹匹配不上时安全地退回箭头，不会渲染出
/// 错误的形状，只是退化成"看不出来是手形/工字"。
enum CursorClassifier {
    private struct Fingerprint: Equatable {
        let size: CGSize
        let hotSpot: CGPoint
    }

    private static let pointingHand = Fingerprint(size: CGSize(width: 32, height: 32), hotSpot: CGPoint(x: 13, y: 8))
    private static let iBeam = Fingerprint(size: CGSize(width: 23, height: 22), hotSpot: CGPoint(x: 12, y: 11))

    static func classify(_ cursor: NSCursor?) -> CursorType {
        guard let cursor else { return .arrow }
        let fingerprint = Fingerprint(size: cursor.image.size, hotSpot: cursor.hotSpot)
        switch fingerprint {
        case pointingHand: return .pointingHand
        case iBeam: return .iBeam
        default: return .arrow
        }
    }

    static func currentType() -> CursorType {
        classify(NSCursor.currentSystem)
    }
}
