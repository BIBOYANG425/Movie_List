import XCTest
@testable import Spool

/// Unit tests for the pure `initialsLetter(from:)` function defined in
/// Components/Avatar.swift.  These pin the public contract so any refactor
/// of the derivation logic fails loudly before it ships.
final class InitialsLetterTests: XCTestCase {

    // MARK: Basic letter derivation

    func testLowercaseNameUppercasesFirst() {
        XCTAssertEqual(initialsLetter(from: "bobby"), "B")
    }

    func testHandleStripsAtSign() {
        XCTAssertEqual(initialsLetter(from: "@yurui"), "Y")
    }

    func testUppercasePassthrough() {
        XCTAssertEqual(initialsLetter(from: "Alice"), "A")
    }

    func testMidStringAtIsIgnored() {
        // "@" is only stripped if it is the *leading* character.
        // "e" comes after "m", but first alnum is "m".
        XCTAssertEqual(initialsLetter(from: "me@example.com"), "M")
    }

    // MARK: Leading whitespace / emoji

    func testLeadingSpaceSkipped() {
        XCTAssertEqual(initialsLetter(from: "  charlie"), "C")
    }

    func testLeadingEmojiSkippedToFirstLetter() {
        XCTAssertEqual(initialsLetter(from: "🎬movie"), "M")
    }

    func testLeadingEmojiAtHandleSkippedToFirstLetter() {
        XCTAssertEqual(initialsLetter(from: "@🎬luna"), "L")
    }

    // MARK: CJK names

    func testCJKFirstCharReturned() {
        // First char of a CJK name is returned as-is (already a letter scalar).
        let result = initialsLetter(from: "陈小明")
        XCTAssertEqual(result, "陈")
    }

    func testCJKHandleReturned() {
        let result = initialsLetter(from: "@张")
        XCTAssertEqual(result, "张")
    }

    // MARK: Digit as first character

    func testLeadingDigitReturned() {
        // Decimal digits are accepted as a first alnum; returned uppercased
        // (no-op for digits).
        XCTAssertEqual(initialsLetter(from: "1up"), "1")
    }

    // MARK: Edge / fallback cases

    func testEmptyStringReturnsFallback() {
        XCTAssertEqual(initialsLetter(from: ""), "?")
    }

    func testWhitespaceOnlyReturnsFallback() {
        XCTAssertEqual(initialsLetter(from: "   "), "?")
    }

    func testPureEmojiReturnsFallback() {
        XCTAssertEqual(initialsLetter(from: "🎬🎭🍿"), "?")
    }

    func testAtSignOnlyReturnsFallback() {
        XCTAssertEqual(initialsLetter(from: "@"), "?")
    }

    func testPunctuationOnlyReturnsFallback() {
        XCTAssertEqual(initialsLetter(from: "---"), "?")
    }
}
