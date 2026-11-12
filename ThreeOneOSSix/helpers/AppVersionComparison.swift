import Foundation

/// UIKit-free version comparison core. Lives in its own file so the CLI
/// policy harness (Tests/run_policy_tests.sh) can verify release-gate logic
/// without dragging in AppUpdateChecker's UIKit/network surface.
/// AppUpdateChecker delegates here; keep all version-compare rules in this
/// one implementation.
enum AppVersionComparison {
    /// Strip surrounding whitespace and a single leading "v"/"V".
    static func normalize(_ version: String) -> String {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        return value
    }

    /// Numeric (not lexicographic) segment comparison: 3.2.10 > 3.2.9,
    /// missing segments count as 0, a "-suffix" is ignored.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = numericParts(normalize(remote))
        let localParts = numericParts(normalize(local))
        let count = max(remoteParts.count, localParts.count)
        for i in 0..<count {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r != l { return r > l }
        }
        return false
    }

    private static func numericParts(_ version: String) -> [Int] {
        let core = version.split(separator: "-").first.map(String.init) ?? version
        return core.split(separator: ".").compactMap { Int($0.filter(\.isNumber)) }
    }
}
