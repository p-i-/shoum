import Foundation

/// Unit tests for the two pure text-processing engines: CommandProcessor (the
/// voice-command lexicon) and TextSplicer.smartJoin (chunk splicing). These are
/// the pieces most often tweaked (lexicon iteration) and least visible when they
/// regress — every build.sh run compiles this file with just those two sources
/// and executes it; a failure fails the build.
///
/// Add a case per lexicon/splicing change. Keep cases as regression locks: they
/// document ACTUAL behavior, including deliberate quirks (e.g. an uppercase
/// replaced-selection does NOT capitalize the chunk).
@main
struct Tests {
    static var failures = 0

    static func check(_ name: String, _ actual: String, _ expected: String) {
        if actual != expected {
            failures += 1
            print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
        }
    }

    static func check(_ name: String, _ actual: [String], _ expected: [String]) {
        if actual != expected {
            failures += 1
            print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
        }
    }

    static func main() {
        // MARK: CommandProcessor — symbols, modes, casing
        let p = CommandProcessor.process
        check("plain text passes through", p("hello world"), "hello world")
        check("ascii symbol", p("ascii slash"), "/")
        check("symbol mid-sentence", p("go over ascii slash there"), "go over / there")
        check("auto-punct stripped before symbol", p("over, ascii slash"), "over /")
        check("paren spacing hugs", p("ascii open paren hello ascii close paren"), "(hello)")
        check("ascii mode span", p("mode ascii slash comma mode normal done"), "/, done")
        check("cap word", p("cap apple pie"), "Apple pie")
        check("new paragraph", p("one new paragraph two"), "one\n\ntwo")
        check("new line", p("one new line two"), "one\ntwo")
        check("unknown ascii trigger stays literal", p("ascii banana split"), "ascii banana split")
        check("all-caps mode span", p("mode all caps warning mode normal ok"), "WARNING ok")
        check("double-quote pairing", p("he said ascii double quote hi ascii double quote"), "he said \"hi\"")
        check("period kept before newline", p("item one. new line item two."), "item one.\nitem two.")
        check("longest phrase wins", p("ascii dot dot dot"), "…")
        check("short synonym", p("ascii at"), "@")
        check("ascii prefix lenient for bare words", p("ascii new line"), "\n")

        // MARK: CommandProcessor.expand — optional-word triggers
        check("expand leading optional", CommandProcessor.expand("(forward) slash"),
              ["forward slash", "slash"])
        check("expand trailing optional", CommandProcessor.expand("less (than)"),
              ["less than", "less"])

        // MARK: TextSplicer.smartJoin — casing, trailing period, seams
        func join(_ chunk: String, _ left: String, _ right: String, _ replaced: String) -> String {
            TextSplicer.smartJoin(chunk: chunk, left: left, right: right, replaced: replaced)
        }
        check("empty box unchanged", join("Hello there.", "", "", ""), "Hello there.")
        check("mid-sentence lowercased", join("Brown fox.", "The quick ", "", ""), "brown fox.")
        check("after sentence end keeps case + space", join("Next thing.", "Done.", "", ""), " Next thing.")
        check("protected I", join("I think so.", "well ", "", ""), "I think so.")
        check("protected acronym", join("NASA launch", "we saw ", "", ""), "NASA launch")
        check("continuing right drops period + spaces", join("it works.", "", "and more", ""), "it works ")
        check("right punctuation drops period, no space", join("done.", "", ") rest", ""), "done")
        check("lowercase replaced selection inherits case", join("New stuff", "", "", "old text"), "new stuff")
        check("uppercase replaced selection does not capitalize", join("new stuff", "", "", "Old"), "new stuff")
        check("mid-sentence continuation lowercases + spaces", join("And then", "we left", "", ""), " and then")
        check("empty chunk", join("   ", "a", "b", ""), "")

        if failures > 0 {
            print("\n\(failures) test(s) FAILED")
            exit(1)
        }
        print("All tests passed.")
    }
}
