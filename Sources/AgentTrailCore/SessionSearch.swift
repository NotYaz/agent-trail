import Foundation

/// The session switcher's type-to-filter. Every word of the query has to
/// appear in at least one field, ignoring case, accents and width, so "trail
/// main" finds the agent-trail session on Claude · Main. Filtering keeps the
/// urgency order; it never re-ranks.
public enum SessionSearch {
    public static func matches(_ query: String, fields: [String]) -> Bool {
        let words = query.split(whereSeparator: { character in character.isWhitespace })
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in
            fields.contains { field in field.range(of: word, options: options) != nil }
        }
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
}
