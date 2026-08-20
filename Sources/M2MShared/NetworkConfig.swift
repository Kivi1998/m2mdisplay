import Foundation

/// 雷雳桥接子网（10.10.10.0/24）使用固定地址。
/// 已通过 `system_profiler SPThunderboltDataType` 和 `ifconfig bridge0` 确认：
/// MacBook Pro 始终使用 .1，iMac 始终使用 .2。因此无需 Bonjour 发现，
/// 直接连接即可，也避免系统意外回退到无线网络。
public enum NetworkConfig {
    public static let senderHost = "10.10.10.1"   // 发送端：MacBook Pro
    public static let receiverHost = "10.10.10.2" // 接收端：iMac

    public static let videoPort: UInt16 = 51230
    public static let cursorPort: UInt16 = 51231
    public static let ackPort: UInt16 = 51232 // 接收端 → 发送端：该光标位置刚刚完成渲染
    public static let controlPort: UInt16 = 51233 // 两端互发正常退出请求
    public static let audioPort: UInt16 = 51234 // 发送端 → 接收端：系统音频
}

/// 双机生命周期控制只经过固定的雷雳桥接网络。使用明确的版本标记，避免端口上
/// 的其他数据被误认为退出指令；收到指令的一端仍会走 AppKit 的正常退出收尾。
public enum PeerControlProtocol {
    public static let quitCommand = "M2M_DISPLAY_QUIT_V1\n"
    public static let acknowledgement = "OK\n"
}
