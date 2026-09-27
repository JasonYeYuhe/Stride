import XCTest
import Foundation

/// `LoginLink.token(from:)`: what one-tap sign-in accepts as a login link. Anything that opens a
/// URL can reach the app, and a URL that passes here signs this device into the token's account,
/// so the rejections matter as much as the acceptances.
final class LoginLinkTests: XCTestCase {

    /// The shape the server emails (server/auth.js: 32 random bytes as hex).
    private let token = "3f2b8c1e9a7d4c05b6e1f0a2d3c4b5a69788f1e2d3c4b5a6978801a2b3c4d5e6"

    /// A string Foundation cannot parse fails the test instead of counting as a rejection —
    /// otherwise a rejection test could pass without ever reaching `LoginLink`.
    private func token(_ string: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)", file: file, line: line)
            return nil
        }
        return LoginLink.token(from: url)
    }

    // MARK: - Accepted

    func testTheLinkTheServerSendsYieldsItsToken() {
        XCTAssertEqual(token("https://stride-api.colorarchive.me/login?token=\(token)"), token)
    }

    /// Hosts and schemes are case-insensitive; a mail client may have upper-cased either.
    func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertEqual(token("HTTPS://Stride-API.ColorArchive.me/login?token=\(token)"), token)
    }

    func testTheDefaultPortIsTheSameLink() {
        XCTAssertEqual(token("https://stride-api.colorarchive.me:443/login?token=\(token)"), token)
    }

    /// A mail client's tracking parameters do not stop iOS opening the app (the AASA only
    /// requires `token`), so they must not stop the sign-in either.
    func testOtherQueryItemsAndAFragmentAreIgnored() {
        XCTAssertEqual(token("https://stride-api.colorarchive.me/login?utm_source=mail&token=\(token)&x=1#top"), token)
    }

    /// The token comes back decoded: a percent-encoded letter is that letter.
    func testPercentEncodedTokenCharactersAreDecoded() {
        XCTAssertEqual(token("https://stride-api.colorarchive.me/login?token=%61bcdef0123456789abcdef"),
                       "abcdef0123456789abcdef")
    }

    /// Looser than today's hex tokens on purpose (see `isPlausibleToken`): the demo account's
    /// 48-hex token and a url-safe base64 token both pass.
    func testOtherUrlSafeTokenFormatsPass() {
        XCTAssertNotNil(token("https://stride-api.colorarchive.me/login?token=\(String(repeating: "ab", count: 24))"))
        XCTAssertNotNil(token("https://stride-api.colorarchive.me/login?token=Zm9vYmFy-_Zm9vYmFyZm9v"))
    }

    // MARK: - Rejected: not our link

    func testOtherHostsAreRejected() {
        for host in ["colorarchive.me", "stride.colorarchive.me", "evil.stride-api.colorarchive.me",
                     "stride-api.colorarchive.me.evil.com", "stride-api.colorarchive.me.", "localhost:3002"] {
            XCTAssertNil(token("https://\(host)/login?token=\(token)"), host)
        }
    }

    func testOtherSchemesAreRejected() {
        for scheme in ["http", "stride", "ftp", "file"] {
            XCTAssertNil(token("\(scheme)://stride-api.colorarchive.me/login?token=\(token)"), scheme)
        }
    }

    func testOtherPathsAreRejected() {
        for path in ["/", "", "/login/", "/Login", "/v1/auth/verify", "/login/extra", "/%6Cogin", "/api/login"] {
            XCTAssertNil(token("https://stride-api.colorarchive.me\(path)?token=\(token)"), path)
        }
    }

    func testAnotherPortOrCredentialsAreRejected() {
        XCTAssertNil(token("https://stride-api.colorarchive.me:8443/login?token=\(token)"))
        XCTAssertNil(token("https://user:pass@stride-api.colorarchive.me/login?token=\(token)"))
    }

    // MARK: - Rejected: no usable token

    func testMissingOrEmptyTokenIsRejected() {
        XCTAssertNil(token("https://stride-api.colorarchive.me/login"))
        XCTAssertNil(token("https://stride-api.colorarchive.me/login?"))
        XCTAssertNil(token("https://stride-api.colorarchive.me/login?token"))
        XCTAssertNil(token("https://stride-api.colorarchive.me/login?token="))
        XCTAssertNil(token("https://stride-api.colorarchive.me/login?Token=\(token)"), "the name is case-sensitive")
        XCTAssertNil(token("https://stride-api.colorarchive.me/login#token=\(token)"), "a fragment is not the query")
    }

    /// Two tokens is ambiguous: the /login page and this could pick different ones.
    func testMultipleTokensAreRejectedEvenWhenEqual() {
        XCTAssertNil(token("https://stride-api.colorarchive.me/login?token=\(token)&token=\(token)"))
        XCTAssertNil(token("https://stride-api.colorarchive.me/login?token=\(token)&token=other0123456789abc"))
    }

    func testImplausibleTokensAreRejected() {
        let rejected = [
            "short",                                      // under 16
            String(repeating: "a", count: 513),           // over 512
            "abc%20def0123456789abcdef",                  // an encoded space decodes to a space
            "abc+def0123456789abcdef",                    // '+' is not a space in a URL query, and not a token character
            "%3Cscript%3Ealert(1)%3C%2Fscript%3E",        // markup
            "abcdef0123456789abcdef%0A",                  // a trailing newline
            "abcdef0123456789%C3%A9abcdef",               // non-ASCII
            "abcdef0123456789.abcdef",
        ]
        for value in rejected {
            XCTAssertNil(token("https://stride-api.colorarchive.me/login?token=\(value)"), value)
        }
    }

    func testTokenLengthBoundaries() {
        XCTAssertNil(token("https://stride-api.colorarchive.me/login?token=\(String(repeating: "a", count: 15))"))
        XCTAssertNotNil(token("https://stride-api.colorarchive.me/login?token=\(String(repeating: "a", count: 16))"))
        XCTAssertNotNil(token("https://stride-api.colorarchive.me/login?token=\(String(repeating: "a", count: 512))"))
    }
}
