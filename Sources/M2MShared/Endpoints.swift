import Foundation

/// 允许覆盖目标主机，便于正式跨设备部署前在同一台机器上运行发送端和接收端，
/// 完成本地回环测试。
public enum Endpoints {
    public static var receiverHost: String {
        ProcessInfo.processInfo.environment["M2M_RECEIVER_HOST"] ?? NetworkConfig.receiverHost
    }
    public static var senderHost: String {
        ProcessInfo.processInfo.environment["M2M_SENDER_HOST"] ?? NetworkConfig.senderHost
    }
}
