import Foundation

/// UTF-16 ranges match native text editing. Display names are snapshots; links use stable IDs.
public struct PersonMention: Codable, Hashable, Sendable {
    public var personID: String
    public var location: Int
    public var length: Int
    public var range: NSRange { NSRange(location: location, length: length) }
    public init(personID: String, location: Int, length: Int) {
        self.personID = personID; self.location = location; self.length = length
    }
}

public enum PersonMentions {
    public static func valid(_ mentions: [PersonMention], in text: String) -> [PersonMention] {
        var end = 0
        return mentions.sorted { $0.location < $1.location }.filter { mention in
            guard mention.location >= end, mention.length > 1, mention.location <= text.utf16.count,
                  mention.length <= text.utf16.count - mention.location,
                  let range = Range(mention.range, in: text), text[range].hasPrefix("@") else { return false }
            end = mention.location + mention.length
            return true
        }
    }

    public static func adjusted(_ mentions: [PersonMention], replacing range: NSRange, with replacement: String) -> [PersonMention] {
        let delta = replacement.utf16.count - range.length
        return mentions.compactMap { mention in
            if mention.location + mention.length <= range.location { return mention }
            if mention.location >= NSMaxRange(range) {
                var shifted = mention; shifted.location += delta; return shifted
            }
            // Editing a name removes only its link, never the user's words.
            return nil
        }
    }

    public static func query(in text: String, selection: NSRange, mentions: [PersonMention]) -> (range: NSRange, name: String)? {
        guard selection.length == 0, selection.location >= 0, selection.location <= text.utf16.count,
              let caret = Range(selection, in: text)?.lowerBound,
              !valid(mentions, in: text).contains(where: { selection.location > $0.location && selection.location <= $0.location + $0.length }) else { return nil }
        let prefix = text[..<caret]
        guard let at = prefix.lastIndex(of: "@"),
              at == text.startIndex || text[text.index(before: at)].isWhitespace || "([{".contains(text[text.index(before: at)]) else { return nil }
        let name = String(text[text.index(after: at)..<caret])
        guard name.utf16.count <= 64, !name.contains(where: { $0.isNewline || ",;:!?@".contains($0) }) else { return nil }
        return (NSRange(at..<caret, in: text), name)
    }

    public static func inserting(_ person: MemoryPerson, in text: String, mentions: [PersonMention], replacing range: NSRange) -> (text: String, mentions: [PersonMention], caret: Int) {
        guard let swiftRange = Range(range, in: text) else { return (text, mentions, text.utf16.count) }
        let label = "@" + person.name
        let replacement = label + " "
        var updated = adjusted(mentions, replacing: range, with: replacement)
        updated.append(PersonMention(personID: person.id, location: range.location, length: label.utf16.count))
        return (text.replacingCharacters(in: swiftRange, with: replacement), updated.sorted { $0.location < $1.location }, range.location + replacement.utf16.count)
    }
}
