import Foundation

/// Splices a transcribed chunk into surrounding box text. Whisper emits each
/// chunk as a standalone sentence ("Putting it through its paces."); smartJoin
/// adjusts capitalization/punctuation/spacing so it fits where it lands.
///
/// Pure and static (like `CommandProcessor`): no state, no AppKit — kept in its
/// own file so `tests/run-tests.swift` can compile it standalone.
enum TextSplicer {

    static func smartJoin(chunk rawChunk: String, left: String, right: String, replaced: String) -> String {
        var chunk = rawChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return chunk }

        let leftTrimmed = left.replacingOccurrences(
            of: "[ \\t]+$", with: "", options: .regularExpression)
        let rightTrimmed = right.replacingOccurrences(
            of: "^[ \\t]+", with: "", options: .regularExpression)

        // --- First-letter case ---
        // Never touch "I..." or acronyms; whisper capitalizes proper nouns on
        // its own and lowercasing those is rarer than mid-sentence splices.
        let firstWord = chunk.split(separator: " ").first.map(String.init) ?? chunk
        let looksProtected = firstWord == "I" || firstWord.hasPrefix("I'")
            || firstWord.count >= 2 && firstWord.prefix(2).allSatisfy { $0.isUppercase }

        if !looksProtected {
            if let replacedFirst = replaced.first(where: { $0.isLetter }) {
                // Inherit the replaced selection's case
                chunk = replacedFirst.isLowercase ? lowercasedFirst(chunk) : chunk
            } else if !leftTrimmed.isEmpty, !leftTrimmed.hasSuffix("\n") {
                // No selection: lowercase unless we're starting a sentence
                let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
                if let lastChar = leftTrimmed.last, !sentenceEnders.contains(lastChar) {
                    chunk = lowercasedFirst(chunk)
                }
            }
        }

        // --- Trailing period ---
        // Drop the chunk's final "." when the text continues mid-sentence
        // (next char is lowercase or punctuation, incl. an existing ".").
        if chunk.hasSuffix(".") && !chunk.hasSuffix("..") {
            if let next = rightTrimmed.first, next.isLowercase || next.isPunctuation {
                chunk = String(chunk.dropLast())
            }
        }

        // --- Spacing at the seams ---
        let punctuationStart: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "…"]
        if let lastLeft = left.last, !lastLeft.isWhitespace, !lastLeft.isNewline,
           let first = chunk.first, !punctuationStart.contains(first) {
            chunk = " " + chunk
        }
        if let firstRight = right.first, !firstRight.isWhitespace,
           !punctuationStart.contains(firstRight),
           let last = chunk.last, !last.isWhitespace {
            chunk += " "
        }

        return chunk
    }

    private static func lowercasedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }
}
