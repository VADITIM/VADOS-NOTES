import Foundation

public enum Identifier {
    public static let notebookPrefix = "nb"
    public static let pagePrefix = "p"
    public static let elementPrefix = "e"

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let timeCharacterCount = 10
    private static let randomCharacterCount = 16

    public static func make(prefix: String, date: Date = Date()) -> String {
        var generator = SystemRandomNumberGenerator()
        return make(prefix: prefix, date: date, using: &generator)
    }

    public static func make<Generator: RandomNumberGenerator>(prefix: String, date: Date, using generator: inout Generator) -> String {
        let milliseconds = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down)))
        var characters: [Character] = []
        characters.reserveCapacity(timeCharacterCount + randomCharacterCount)
        for position in (0..<timeCharacterCount).reversed() {
            characters.append(alphabet[Int((milliseconds >> (UInt64(position) * 5)) & 31)])
        }
        for _ in 0..<randomCharacterCount {
            characters.append(alphabet[Int(generator.next() & 31)])
        }
        return prefix + "_" + String(characters)
    }

    public static func creationDate(of identifier: String) -> Date? {
        guard let separator = identifier.firstIndex(of: "_") else { return nil }
        let characters = Array(identifier[identifier.index(after: separator)...].prefix(timeCharacterCount))
        guard characters.count == timeCharacterCount else { return nil }
        var milliseconds: UInt64 = 0
        for character in characters {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            milliseconds = milliseconds << 5 | UInt64(value)
        }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    public static func hasPrefix(_ prefix: String, _ identifier: String) -> Bool {
        identifier.hasPrefix(prefix + "_") && identifier.count > prefix.count + 1
    }
}
