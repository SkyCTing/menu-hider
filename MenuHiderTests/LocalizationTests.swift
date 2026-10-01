import XCTest

@testable import MenuHider

final class LanguageTests: XCTestCase {
    func testTheSystemChoiceIsTheApplicationsOwnResolution() {
        XCTAssertEqual(Language.system.bundle, Bundle.main, "macOS resolves the system preference for us")
    }

    func testAForcedLanguageReadsItsOwnTable() {
        XCTAssertEqual(Strings(language: .english)(.showLeftZone), "Show Left Zone")
        XCTAssertEqual(Strings(language: .chinese)(.showLeftZone), "显示左区")
    }

    func testAForcedLanguageAgreesWithTheTableItsBundleHolds() {
        let expected = Language.chinese.bundle.localizedString(
            forKey: Text.quit.rawValue, value: nil, table: nil)

        XCTAssertEqual(Strings(language: .chinese)(.quit), expected)
        XCTAssertNotEqual(expected, Text.quit.rawValue, "an untranslated key would come back as itself")
    }

    /// A language is named in itself, whatever the interface is currently in.
    func testEveryLanguageNamesItself() {
        XCTAssertEqual(Language.allCases.map(\.name), ["Follow System", "English", "简体中文"])
    }
}

final class StringsTests: XCTestCase {
    /// Both tables ship inside the built app, so the test reads what users get rather than the source.
    private func table(_ identifier: String) throws -> [String: String] {
        let bundle = try XCTUnwrap(Language(rawValue: identifier)?.bundle, "no \(identifier) bundle")
        let url = try XCTUnwrap(
            bundle.url(forResource: "Localizable", withExtension: "strings"), "no strings file in \(identifier)")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "unreadable \(identifier)")
    }

    /// The guard that keeps a new string from being translated into only one language.
    func testEveryTextExistsInEveryLanguage() throws {
        for language in ["english", "chinese"] {
            let strings = try table(language)
            for text in Text.allCases {
                let value = strings[text.rawValue]
                XCTAssertNotNil(value, "\(language) is missing \(text.rawValue)")
                XCTAssertFalse(value?.isEmpty ?? true, "\(language) has an empty \(text.rawValue)")
            }
        }
    }

    /// The other direction: a key nobody uses any more is a string waiting to be mistranslated.
    func testNoTableCarriesAKeyTheCodeDoesNotUse() throws {
        let known = Set(Text.allCases.map(\.rawValue))
        for language in ["english", "chinese"] {
            let extra = Set(try table(language).keys).subtracting(known)
            XCTAssertTrue(extra.isEmpty, "\(language) carries unused keys: \(extra.sorted())")
        }
    }

    func testTheTablesHoldDifferentWordsForTheSameKeys() throws {
        let english = try table("english")
        let chinese = try table("chinese")

        // Not a translation check, a canary: a key copied from one table into the other would leave
        // the Chinese interface reading English.
        let identical = Text.allCases.filter { text in
            guard let left = english[text.rawValue], let right = chinese[text.rawValue] else { return false }
            // Names of languages are the same in both tables on purpose.
            return left == right && !text.rawValue.hasPrefix("menu.language")
        }
        XCTAssertTrue(identical.isEmpty, "same wording in both tables: \(identical.map(\.rawValue).sorted())")
    }

    func testFormatArgumentsSurviveTranslation() throws {
        // A dropped %d or %@ is the classic translation bug: the sentence renders as literal
        // punctuation, or crashes on an argument it does not have.
        for text in Text.allCases {
            let expected = placeholders(in: try table("english")[text.rawValue] ?? "")
            for language in ["chinese"] {
                let found = placeholders(in: try table(language)[text.rawValue] ?? "")
                XCTAssertEqual(found, expected, "\(text.rawValue) has different placeholders in \(language)")
            }
        }
    }

    private func placeholders(in format: String) -> [String] {
        // %@ and %d are all these tables use; anything else would be a surprise worth failing on.
        var found: [String] = []
        var characters = Substring(format)
        while let percent = characters.firstIndex(of: "%") {
            let next = characters.index(after: percent)
            guard next < characters.endIndex else { break }
            found.append(String(characters[percent...next]))
            characters = characters[characters.index(after: next)...]
        }
        return found
    }
}
