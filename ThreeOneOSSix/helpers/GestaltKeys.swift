import Foundation
import CoreFoundation

/// Canonical MobileGestalt CacheExtra keys, cross-checked against
/// GestaltX (GPL-3.0), MGKeys, Nugget and mond. Do not invent keys: on
/// iOS 27 a key that did not exist in the original cache can trip the
/// boot-time cache validation and force a full rebuild (restart bounce).
enum GestaltKeys {
    static let gestaltPath = MobileGestaltService.gestaltPath

    // Identity / region cluster
    static let artwork = "oPeik/9e8lQWMszEjbPzng"
    static let productType = "h9jDsbgj7xIVeIQ8S3/X3Q"
    static let boardConfig = "oYicEKzVTz4/CxxE05pEgQ"
    static let cpuType = "5pYKlGnYYBzGvAlIU8RjEQ"
    static let modelNumber = "97JDvERpVwO+GHtthIh7hA"
    static let regionCode = "h63QSdBCiT/z0WU6rdQv6Q"
    static let regionInfo = "zHeENZu+wbg7PUprwNwBWg"
    static let legacyRegionInfo = "yK+xavymRGZ3xWc1tb8XDg"
    static let deviceName1 = "Z/dqyWS6OZTRy10UcmUAhw"
    static let deviceName2 = "bbtR9jQx50Fv5Af/affNtA"

    // Siri AI experiment cluster (YumEdit parity; iOS 27+ only)
    static let siriMode = "a3n5T9sFtlyQ74NEp9ESxg"
    static let aiCapability = "A62OafQ85EJAiiqKn4agtg"

    // Artwork sub-dictionary keys
    static let artworkSubtype = "ArtworkDeviceSubType"
    static let artworkDescription = "ArtworkDeviceProductDescription"

    /// Keys that participate in device identity. Writing any of these is
    /// gated behind the risk confirmation flow.
    static let identityKeys: Set<String> = [
        productType, boardConfig, cpuType, modelNumber,
        regionCode, regionInfo, legacyRegionInfo, siriMode,
    ]
}

/// Exact CoreFoundation type detection (Erosion-CN parity): NSNumber must be
/// disambiguated into Boolean vs Integer vs Real, or a plist round-trip turns
/// `<true/>` into `<integer>1</integer>` — the bug that black-screened
/// cameras after a Gestalt edit in upstream Erosion.
enum GestaltValueKind: String, CaseIterable, Identifiable {
    case string = "String"
    case integer = "Integer"
    case real = "Real"
    case boolean = "Boolean"
    case data = "Data"
    case date = "Date"
    case array = "Array"
    case dictionary = "Dictionary"

    var id: String { rawValue }

    static func detect(_ value: Any) -> GestaltValueKind {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean }
            return CFNumberIsFloatType(unsafeBitCast(number, to: CFNumber.self)) ? .real : .integer
        }
        if value is Date { return .date }
        if value is Data { return .data }
        if value is [String: Any] { return .dictionary }
        if value is [Any] { return .array }
        return .string
    }

    /// Parse user text into a value of this kind. Array/Dictionary accept an
    /// XML plist fragment so nested Data/Boolean types survive.
    func parse(_ text: String) throws -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .string: return text
        case .integer:
            if let value = Int64(trimmed) { return NSNumber(value: value) }
            guard let value = UInt64(trimmed) else {
                throw GestaltValueError(kind: self, message: "gestalt.field.error_integer")
            }
            return NSNumber(value: value)
        case .real:
            guard let value = Double(trimmed), value.isFinite else {
                throw GestaltValueError(kind: self, message: "gestalt.field.error_real")
            }
            return NSNumber(value: value)
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "1": return NSNumber(value: true)
            case "false", "0": return NSNumber(value: false)
            default:
                throw GestaltValueError(kind: self, message: "gestalt.field.error_boolean")
            }
        case .date:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = formatter.date(from: trimmed) { return value }
            formatter.formatOptions = [.withInternetDateTime]
            guard let value = formatter.date(from: trimmed) else {
                throw GestaltValueError(kind: self, message: "gestalt.field.error_date")
            }
            return value
        case .data:
            guard let value = Data(base64Encoded: trimmed.filter { !$0.isWhitespace }) else {
                throw GestaltValueError(kind: self, message: "gestalt.field.error_data")
            }
            return value
        case .array, .dictionary:
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\">\(text)</plist>"
            guard
                let value = try? PropertyListSerialization.propertyList(
                    from: Data(xml.utf8), options: [], format: nil
                ),
                validateShape(value)
            else {
                throw GestaltValueError(kind: self, message: "gestalt.field.error_fragment")
            }
            return value
        }
    }

    /// Render an existing value into editable text.
    static func render(_ value: Any) -> String {
        switch GestaltValueKind.detect(value) {
        case .string: return value as? String ?? ""
        case .boolean: return (value as? NSNumber)?.boolValue == true ? "true" : "false"
        case .integer, .real: return "\(value)"
        case .date:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: value as! Date)
        case .data: return (value as! Data).base64EncodedString()
        case .array, .dictionary:
            guard
                let data = try? PropertyListSerialization.data(
                    fromPropertyList: value, format: .xml, options: 0
                ),
                let xml = String(data: data, encoding: .utf8)
            else { return "" }
            // Strip the plist wrapper so the fragment round-trips.
            var body = xml
            for wrapper in [
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
                "<plist version=\"1.0\">", "</plist>",
            ] {
                body = body.replacingOccurrences(of: wrapper, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return body
        }
    }

    private func validateShape(_ value: Any) -> Bool {
        switch self {
        case .array: return value is [Any]
        case .dictionary: return value is [String: Any]
        default: return false
        }
    }
}

struct GestaltValueError: Error, LocalizedError {
    let kind: GestaltValueKind
    let messageKey: String
    var errorDescription: String? { messageKey }

    init(kind: GestaltValueKind, message: String) {
        self.kind = kind
        self.messageKey = message
    }
}
