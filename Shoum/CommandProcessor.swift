import Foundation

/// Turns spoken command words into symbols and formatting — "speak markdown".
/// Pure and static (like `TextSplicer.smartJoin`): no state between calls, so
/// it's easy to test and reason about (see tests/run-tests.swift). Applied to
/// each transcription chunk before it splices into the box.
///
/// THE FULL MODEL, THE DEFAULT LEXICON, THE SPACING RULES, AND HOW TO REVISE ARE
/// DOCUMENTED IN `lexicon.md` — read that first. The data below IS the lexicon;
/// to change a trigger word or symbol, edit these tables (and `primer`).
enum CommandProcessor {

    // MARK: Lexicon (defaults — see lexicon.md)

    /// ASCII symbols. Triggered by "ascii <words>" anywhere, or by the bare
    /// <words> inside a "mode ascii … mode normal" span. Matching is always
    /// longest-phrase-first, so multi-word triggers win over their prefixes.
    static let symbols: [(String, [String])] = [
        ("(", ["open paren", "open parenthesis", "left paren"]),
        (")", ["close paren", "close parenthesis", "right paren"]),
        ("[", ["open bracket", "left bracket"]),
        ("]", ["close bracket", "right bracket"]),
        ("{", ["open brace", "left brace"]),
        ("}", ["close brace", "right brace"]),
        ("<", ["less (than)", "open angle"]),
        (">", ["greater (than)", "close angle"]),
        ("±", ["plus minus"]),
        (":", ["colon"]),
        (";", ["semicolon"]),
        (",", ["comma"]),
        (".", ["period", "full stop", "dot"]),
        ("…", ["ellipsis", "dot dot dot"]),
        ("/", ["(forward) slash"]),
        ("\\", ["backslash"]),
        ("|", ["pipe"]),
        ("-", ["dash", "hyphen", "minus"]),
        ("--", ["double dash"]),
        ("+", ["plus"]),
        ("=", ["equals"]),
        ("_", ["underscore"]),
        ("*", ["asterisk", "star"]),
        ("^", ["caret"]),
        ("~", ["tilde"]),
        ("`", ["backtick"]),
        ("@", ["at sign", "at"]),
        ("#", ["hash", "number sign"]),
        ("£", ["pound"]),
        ("$", ["dollar"]),
        ("€", ["euro"]),
        ("%", ["percent"]),
        ("&", ["ampersand"]),
        ("!", ["exclamation (mark)", "pling", "bang"]),
        ("?", ["question (mark)"]),
        ("'", ["single (quote)", "apostrophe"]),
        ("\"", ["double (quote)"]),
        ("§", ["section"]),
        ("•", ["bullet"]),
    ]

    /// Bare words — take effect WITHOUT the "ascii" prefix.
    static let bareWords: [(String, [String])] = [
        ("\n\n", ["new paragraph"]),
        ("\n", ["new line", "newline"]),
    ]

    /// Initial-prompt fragment that primes whisper to emit the control words
    /// reliably (the symbol names already self-recognise; this mainly steadies
    /// the "mode …" words — measured: it flips "Modasci" → "mode ascii").
    /// `ServerManager` appends this to prompt.txt when voice commands are on.
    static let primer: String = {
        // The full "ascii <name>" slew measurably helps whisper hear command
        // words in hard contexts (e.g. it recovers "ascii ampersand" inside a
        // brand name). Generated from the lexicon so it can't drift.
        let names: [String] = symbols.compactMap { (_, triggers) in
            triggers.first?.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        }
        return "Spoken dictation commands: mode ascii, mode normal, mode all caps, cap, "
            + "newline, new paragraph, and ascii symbols: "
            + names.map { "ascii \($0)" }.joined(separator: ", ") + "."
    }()

    // Spacing model (see lexicon.md "Spacing"). Symbols not listed keep the
    // spaces around them as spoken.
    private static let attachRight: Set<Character> = ["(", "[", "{"]            // no space AFTER
    private static let attachLeft: Set<Character> = [")", "]", "}", ",", ".", ":", ";", "!", "?", "%"] // no space BEFORE
    private static let attachBoth: Set<Character> = ["_"]                       // no space EITHER side

    // MARK: Process

    static func process(_ text: String) -> String {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return text }

        var out: [String] = []
        var asciiMode = false
        var capsMode = false
        var i = 0

        // Emit a command's output, first stripping whisper's auto-punctuation
        // ( , . ; : ) off the previous word — when you pause around a command,
        // whisper grammatically punctuates the surrounding words, which then
        // collides with the symbol ("over," + / → over,/). Newlines are exempt
        // (a period before a line break is usually intentional, e.g. list items).
        func emit(_ sym: String) {
            if !sym.contains("\n"), let last = out.last {
                let stripped = stripTrailing(last)
                if stripped.isEmpty { out.removeLast() } else { out[out.count - 1] = stripped }
            }
            out.append(sym)
        }

        while i < tokens.count {
            let w = clean(tokens[i])

            // --- mode commands ---
            if w == "mode", i + 1 < tokens.count {
                let m = clean(tokens[i + 1])
                if m == "ascii" { asciiMode = true; i += 2; continue }
                if m == "normal" { asciiMode = false; capsMode = false; i += 2; continue }
                if m == "all", i + 2 < tokens.count, clean(tokens[i + 2]) == "caps" {
                    capsMode = true; i += 3; continue
                }
            }

            // --- ascii-prefixed symbol (or, leniently, a bare word) ---
            if w == "ascii" {
                if let (sym, n) = match(tokens, i + 1, symbolMap, maxSymbolWords) {
                    emit(sym); i += 1 + n; continue
                }
                if let (sym, n) = match(tokens, i + 1, bareMap, maxBareWords) {
                    emit(sym); i += 1 + n; continue // "ascii new line" → newline
                }
                out.append(tokens[i]); i += 1; continue // unknown trigger → keep "ascii" literal
            }

            // --- cap <word> ---
            if w == "cap", i + 1 < tokens.count {
                out.append(capFirst(tokens[i + 1])); i += 2; continue
            }

            // --- bare symbols while in ascii-mode ---
            if asciiMode, let (sym, n) = match(tokens, i, symbolMap, maxSymbolWords) {
                emit(sym); i += n; continue
            }

            // --- bare structural words ---
            if let (sym, n) = match(tokens, i, bareMap, maxBareWords) {
                emit(sym); i += n; continue
            }

            // --- ordinary word ---
            out.append(capsMode ? tokens[i].uppercased() : tokens[i]); i += 1
        }

        return reassemble(out)
    }

    // MARK: Lookups (precomputed from the lexicon)

    private static let symbolMap = buildMap(symbols)
    private static let bareMap = buildMap(bareWords)
    private static let maxSymbolWords = maxWords(symbols)
    private static let maxBareWords = maxWords(bareWords)

    private static func buildMap(_ entries: [(String, [String])]) -> [String: String] {
        var m: [String: String] = [:]
        for (out, triggers) in entries {
            for t in triggers { for v in expand(t) { m[v.lowercased()] = out } }
        }
        return m
    }
    private static func maxWords(_ entries: [(String, [String])]) -> Int {
        var m = 1
        for (_, triggers) in entries {
            for t in triggers { for v in expand(t) { m = max(m, v.split(separator: " ").count) } }
        }
        return m
    }

    /// Expand a trigger's optional parenthesised words into every variant:
    /// "(forward) slash" → ["forward slash", "slash"], "less (than)" → ["less
    /// than", "less"]. Each `(word)` is independently optional. The Commands tab
    /// shows the un-expanded form (with the parens) as the spoken-name hint.
    static func expand(_ phrase: String) -> [String] {
        var variants: [[String]] = [[]]
        for tok in phrase.split(separator: " ").map(String.init) {
            if tok.hasPrefix("(") && tok.hasSuffix(")") {
                let word = String(tok.dropFirst().dropLast())
                variants = variants.flatMap { [$0 + [word], $0] }
            } else {
                variants = variants.map { $0 + [tok] }
            }
        }
        return variants.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }
    }

    // MARK: Helpers

    /// Lowercased, stripped of leading/trailing non-alphanumerics — so trailing
    /// punctuation whisper attached ("paren,") doesn't block a match. The cost:
    /// that punctuation is dropped on a match (see lexicon.md limitations).
    private static func clean(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Longest-phrase-first match of `map` against tokens from `start`.
    private static func match(_ tokens: [String], _ start: Int,
                              _ map: [String: String], _ maxN: Int) -> (String, Int)? {
        let upper = min(maxN, tokens.count - start)
        guard upper >= 1 else { return nil }
        for n in stride(from: upper, through: 1, by: -1) {
            let phrase = (start..<start + n).map { clean(tokens[$0]) }.joined(separator: " ")
            if let out = map[phrase] { return (out, n) }
        }
        return nil
    }

    private static func capFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    /// Drop a trailing run of whisper-style auto-punctuation ( , . ; : ).
    private static func stripTrailing(_ s: String) -> String {
        var t = Substring(s)
        while let last = t.last, ",.;:".contains(last) { t = t.dropLast() }
        return String(t)
    }

    /// Join output tokens, attaching symbols per the spacing model and never
    /// putting spaces around inserted newlines.
    private static func reassemble(_ raw: [String]) -> String {
        let tokens = raw.filter { !$0.isEmpty }
        // Tag double-quotes as opening/closing by order (1st = open, 2nd = close,
        // …). An odd count just leaves the last one acting as an opener — graceful,
        // no crash.
        var dq = 0
        var openQuote = [Bool](repeating: false, count: tokens.count)
        for i in tokens.indices where tokens[i] == "\"" {
            openQuote[i] = (dq % 2 == 0); dq += 1
        }
        var s = ""
        for i in tokens.indices {
            let tok = tokens[i]
            if i == 0 { s = tok; continue }
            let prev = s.last!, first = tok.first!
            var noSpace = prev == "\n" || first == "\n"
                || attachRight.contains(prev) || attachLeft.contains(first)
                || attachBoth.contains(prev) || attachBoth.contains(first)
            // Double-quote pairing: an opening " hugs the following token, a
            // closing " hugs the preceding one (he said " hi " → he said "hi").
            if tokens[i - 1] == "\"" { noSpace = openQuote[i - 1] }   // after a quote
            if tok == "\"" { noSpace = !openQuote[i] }                // this token is a quote
            s += (noSpace ? "" : " ") + tok
        }
        return s
    }
}
