import Foundation
import CryptoKit
#if os(iOS)
import UIKit
#endif

final class AnalyticsService: @unchecked Sendable {
    static let shared = AnalyticsService()

    private let appID = "YOUR_TELEMETRYDECK_APP_ID"
    private let endpoint = URL(string: "https://nom.telemetrydeck.com/v2/")!
    private let session = URLSession(configuration: .ephemeral)
    private let anonymousUserID: String

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "stride_analytics_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "stride_analytics_enabled") }
    }

    private init() {
        // Stable anonymous user ID: identifierForVendor on iOS, stored UUID on macOS
        let rawID: String
        #if os(iOS)
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString {
            rawID = vendorID
        } else {
            rawID = Self.storedUUID()
        }
        #else
        rawID = Self.storedUUID()
        #endif

        // SHA256 hash for privacy
        let hash = SHA256.hash(data: Data(rawID.utf8))
        self.anonymousUserID = hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func storedUUID() -> String {
        let key = "stride_analytics_uuid"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }

    // MARK: - Public API

    func send(_ type: String, metadata: [String: String] = [:]) {
        guard isEnabled else { return }
        // Dormant until a real TelemetryDeck App ID is configured. Without this,
        // signals would POST to TelemetryDeck with the placeholder ID — the data
        // still leaves the device even though the server discards it. Auto-activates
        // once `appID` is set to a real App ID.
        guard appID != "YOUR_TELEMETRYDECK_APP_ID" else { return }

        var payload = metadata
        payload["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        payload["buildNumber"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        #if os(iOS)
        payload["platform"] = "iOS"
        payload["osVersion"] = UIDevice.current.systemVersion
        #elseif os(macOS)
        payload["platform"] = "macOS"
        payload["osVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        let signal: [String: Any] = [
            "appID": appID,
            "clientUser": anonymousUserID,
            "type": type,
            "payload": payload
        ]

        let body: [String: Any] = [
            "signals": [signal]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        // Fire-and-forget
        session.dataTask(with: request).resume()
    }
}
