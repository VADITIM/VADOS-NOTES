import Foundation

public enum Timestamp {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static func now() -> Date {
        rounded(Date())
    }

    public static func rounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    public static func format(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    public static func parse(_ text: String) -> Date? {
        fractionalFormatter.date(from: text) ?? wholeSecondFormatter.date(from: text)
    }

    static func encode(_ date: Date, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(format(date))
    }

    static func decode(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = parse(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 timestamp: \(text)")
        }
        return date
    }
}
