import Foundation

/// The token in a one-tap sign-in link — and nothing else is one.
///
/// The magic-link email points at `https://stride-api.colorarchive.me/login?token=…`
/// (server/origins.js `loginUrl`). With the associated-domains entitlement and the server's AASA
/// file (components `/login` + `?token=*`, server/index.js), iOS and macOS hand that URL to the
/// app instead of Safari, and the app signs in with it (StrideApp → `AuthService.handleLoginLink`).
///
/// Anything can hand the app a URL: another app, a web page, a QR code. A URL that reaches the
/// sign-in path is a request to sign this device into whichever account the token belongs to, so
/// only exactly the shape the server sends is accepted — https, our host, `/login`, one token.
/// It is a universal link, not a custom scheme, for the same reason: any installed app can claim
/// `stride://` and be handed the token.
///
/// Pure and in `Shared/` so StrideTests covers it host-less (LoginLinkTests).
enum LoginLink {
    static let host = "stride-api.colorarchive.me"
    static let path = "/login"

    /// The magic-link token, or nil for every URL that is not exactly a login link.
    static func token(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == host,
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              // The encoded path, so "/%6Cogin" or "/login%2F" is not taken for "/login". The AASA
              // component is "/login" exactly; "/login/" is not a link the server ever sends.
              components.percentEncodedPath == path
        else { return nil }

        // Exactly one. With two, which one the server's /login page would show and which one this
        // would take could differ — an ambiguous link signs nobody in. Other items (a mail
        // client's tracking parameters) are ignored: the AASA only requires `token` to be present,
        // so iOS still opens the app for such a link, and rejecting it would strand the user.
        let tokens = (components.queryItems ?? []).filter { $0.name == "token" }
        guard tokens.count == 1, let token = tokens[0].value, isPlausibleToken(token) else { return nil }
        return token
    }

    /// Letters, digits, `-` and `_`, 16…512 characters.
    ///
    /// The server's tokens are 64 hex characters (server/auth.js `createOpaqueToken`), but the
    /// check is deliberately looser than that: once the app is installed, iOS opens every
    /// `/login?token=` link in the app and never shows the /login page, so a token this rejects
    /// is a sign-in that silently does nothing. Any url-safe token format the server might move
    /// to still passes; spaces, quotes, markup, a one-character "token" and runaway lengths do
    /// not. `queryItems` has already percent-decoded the value, so an encoded space or `<` is
    /// rejected as itself.
    static func isPlausibleToken(_ token: String) -> Bool {
        guard (16...512).contains(token.unicodeScalars.count) else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_": return true
            default: return false
            }
        }
    }
}
