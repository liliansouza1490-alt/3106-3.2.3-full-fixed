import Foundation

enum ExploitSupportPolicy {
    static let verifiedIOS17Range = "17.0–17.7.x"
    static let verifiedIOS18Range = "18.0–18.7.1"
    static let verifiedIOS26BadQueryRange = "26.0–26.6.1"
    static let verifiedIOS26WorseQueryRange = "26.0–26.7.2"
    static let verifiedIOS27Range = "27.0 / 27.1 / 27.2 / 27.3"

    static func supportsKernelExploit(major: Int, minor: Int, patch: Int) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }

        if major == 17 {
            return minor <= 7
        }

        if major == 18 {
            return minor < 7 || (minor == 7 && patch <= 1)
        }

        return false
    }

    /// bad_query still works on the builds it was verified for; it is kept as
    /// a fallback on 26.0–26.6.1 when no App Group is present.
    static func supportsBadQuery(major: Int, minor: Int, patch: Int) -> Bool {
        guard major == 26, minor >= 0, patch >= 0 else { return false }
        return minor < 6 || (minor == 6 && patch <= 1)
    }

    /// worse_query (forcequitOS) covers iOS 26.0–26.7.2 and 27.x through 27.3.
    /// Matches the upstream PoC range + operator-confirmed 27.3 beta.
    static func supportsWorseQuery(major: Int, minor: Int, patch: Int) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }
        if major == 26 {
            // Full upstream range: 26.0 – 26.7.2
            if minor < 7 { return true }
            return minor == 7 && patch <= 2
        }
        if major == 27 {
            return minor <= 3
        }
        return false
    }

    /// Kept for the experimental-features gate; no release currently maps
    /// to an experimental tier.
    static func isExperimental(major: Int, minor: Int) -> Bool {
        false
    }

    static func isSupported(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        if supportsKernelExploit(major: major, minor: minor, patch: patch) { return true }
        if supportsWorseQuery(major: major, minor: minor, patch: patch) { return true }
        if supportsBadQuery(major: major, minor: minor, patch: patch) { return true }
        return isExperimental(major: major, minor: minor)
    }
}
