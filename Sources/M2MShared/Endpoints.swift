import Foundation

/// Allows overriding the target host for local loopback testing (both Sender and
/// Receiver running on the same machine) before real cross-machine deployment.
public enum Endpoints {
    public static var receiverHost: String {
        ProcessInfo.processInfo.environment["M2M_RECEIVER_HOST"] ?? NetworkConfig.receiverHost
    }
    public static var senderHost: String {
        ProcessInfo.processInfo.environment["M2M_SENDER_HOST"] ?? NetworkConfig.senderHost
    }
}
