import Foundation

/// Fixed addressing on the Thunderbolt Bridge subnet (10.10.10.0/24), confirmed via
/// `system_profiler SPThunderboltDataType` / `ifconfig bridge0` diagnostics: MacBook Pro
/// is always .1, iMac is always .2 on this link, so we skip Bonjour discovery entirely
/// and connect directly — one less moving part that could fall back to Wi-Fi.
public enum NetworkConfig {
    public static let senderHost = "10.10.10.1"   // MacBook Pro
    public static let receiverHost = "10.10.10.2" // iMac

    public static let videoPort: UInt16 = 51230
    public static let cursorPort: UInt16 = 51231
}
