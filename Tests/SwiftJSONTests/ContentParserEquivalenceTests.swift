//  ContentParserEquivalenceTests.swift
//
//  Checks that `JSON(data:)` behaves exactly like `JSONSerialization` followed by `JSON(_:)`, which it did before
//  `ContentParser` existed: the same content down to the concrete `NSNumber` classes, types and values, and the same
//  error for everything `JSONSerialization` rejects. Every check also asserts whether `ContentParser` handled the data
//  itself, so that a fallback to `JSONSerialization` cannot make a test pass unnoticed.

import XCTest
@testable import SwiftyJSON

class ContentParserEquivalenceTests: XCTestCase {

    func testParsesValuesItselfLikeJSONSerialization() {
        let samples: [String] = [
            #"{"a":1,"b":-2,"c":1.5,"d":-0.0,"e":0.5,"f":-0.25,"g":1.0,"h":100.125}"#,
            #"{"t":true,"f":false,"n":null}"#,
            #"{"empty":{},"emptyArray":[],"nested":{"a":[{"b":[1,2,[3]]}]}}"#,
            #"[1,"two",3.0,null,true,{"k":"v"},[]]"#,
            "  {\"padded\" : [ 1 , 2 ] }  ",
            "{\"whitespace\":\t[\n1,\r2 ]\n}",
            #"{"duplicate":1,"duplicate":2}"#,
            #""justAString""#,
            "42",
            "null",
            "true",
        ]
        for sample in samples {
            assertParsedByContentParser(Data(sample.utf8), options: .fragmentsAllowed)
        }
    }

    func testParsesStringsItselfLikeJSONSerialization() {
        let samples: [String] = [
            #""a\"b\\c\/d\be\ff\ng\rh\ti""#,
            #""ä€😀""#,
            #""ä€😀""#,
            #""mixed ä and ä""#,
            #""ä€😀""#,
            #"{"äKey":"escaped key","äKey":"literal key"}"#,
            #""a\u0000b""#,
            #""￿￾""#,
            "\"\u{7F}\"",
            "\"\u{FFFF}\"",
            "\"\u{10FFFF}\"",
            #""""#,
        ]
        for sample in samples {
            assertParsedByContentParser(Data(sample.utf8), options: .fragmentsAllowed)
        }
    }

    func testParsesNumbersItselfLikeJSONSerialization() {
        let samples: [String] = [
            "0", "-0", "-0.0", "0.0", "7", "-7",
            "123456789012345678", "-123456789012345678", "999999999999999999",
            "0.123456789012345", "12345678901234.5", "0.000000000000001",
            // `ContentParser` hands these to `JSONSerialization` one number at a time.
            "1234567890123456789", "9223372036854775807", "-9223372036854775808",
            "9223372036854775808", "18446744073709551615", "18446744073709551616", "-9223372036854775809",
            "123456789012345678901234567890",
            "0.1234567890123456", "0.12345678901234567", "0.123456789012345678", "0.30000000000000004",
            "1.000000000000000000", "12345678901234567.5", "0.00000000000000000001",
            "1e3", "1E3", "1e+3", "1e-3", "-1.2e+10", "1.5e3", "100e-2", "0e0", "-0e-0",
            "1e308", "1.7976931348623157e308", "5e-324", "2e-324", "1E-400", "1.5e-400",
            "-1e400", "-1.8e308",
            "1.23456789012345678e5",
        ]
        for sample in samples {
            assertParsedByContentParser(Data(sample.utf8), options: .fragmentsAllowed)
            assertParsedByContentParser(Data("[\(sample)]".utf8), options: [])
            assertParsedByContentParser(Data("{\"n\":\(sample)}".utf8), options: [])
        }
    }

    func testParsesRandomNumbersLikeJSONSerialization() {
        var generator = SplitMix64(seed: 0x5EED)
        for _ in 0..<20_000 {
            let data = Data("[\(Self.randomNumber(using: &generator))]".utf8)
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                assertPassedToJSONSerialization(data, options: [])
            } else {
                assertParsedByContentParser(data, options: [])
            }
        }
    }

    func testParsesDocumentsStartingWithAByteOrderMarkItself() {
        for sample in [#"{"a":1}"#, " [1] ", "42"] {
            assertParsedByContentParser(Data([0xEF, 0xBB, 0xBF]) + Data(sample.utf8), options: .fragmentsAllowed)
        }
    }

    func testParsesTheDeepestNestingJSONSerializationAcceptsItself() {
        for sample in Self.nestedSamples(enclosingContainerCount: 512) + [Self.arrays(513, ""), Self.arrays(512, "{}")] {
            assertParsedByContentParser(Data(sample.utf8), options: [])
        }
    }

    func testParsesTheDeepestNestingOnABackgroundThreadStack() {
        let data = Data(Self.arrays(511, #"{"a":1}"#).utf8)
        let parsed = expectation(description: "parsed")
        var content: Content?
        let thread = Thread {
            content = ContentParser.parse(data: data, options: [])
            parsed.fulfill()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        wait(for: [parsed], timeout: 10)
        XCTAssertNotNil(content)
    }

    func testPassesMalformedDocumentsToJSONSerialization() {
        let samples: [String] = [
            "", " ", "{", "[", "}", "]", #"{"a"}"#, #"{"a":}"#, #"{"a":1,}"#, "[1,]", "{,}", "[,1]", "[1 2]",
            #"{"a" 1}"#, #"{a:1}"#, #"{1:1}"#, "{\"a\":1}trailing", "[1]]", "tru", "nul", "fals", "True", "NULL",
            "\"unterminated", #""\"#, #""\x""#, #""\u12""#, #""\u12G4""#, "'single'",
            "NaN", "Infinity", "-Infinity", "undefined", "/* comment */ 1",
        ]
        for sample in samples {
            assertPassedToJSONSerialization(Data(sample.utf8), options: .fragmentsAllowed)
        }
    }

    func testPassesMalformedNumbersToJSONSerialization() {
        let samples: [String] = [
            "-", "+1", "--1", "01", "-01", "00", "007", ".5", "-.5", "1.", "1.e5", "1e", "1e+", "1e-", "1E",
            "0x10", "1_000", "1.5.3", "1e5e5", "- 1", "1 .5",
        ]
        for sample in samples {
            assertPassedToJSONSerialization(Data(sample.utf8), options: .fragmentsAllowed)
            assertPassedToJSONSerialization(Data("[\(sample)]".utf8), options: [])
        }
    }

    func testPassesNumbersJSONSerializationRejectsToIt() {
        for sample in ["1e400", "1E400", "1e309", "1.8e308", "9e308", "1.23456789012345678901e300", "1.23456789012345678901e-300"] {
            assertPassedToJSONSerialization(Data(sample.utf8), options: .fragmentsAllowed)
            assertPassedToJSONSerialization(Data("[1,\(sample),2]".utf8), options: [])
        }
    }

    func testPassesUnescapedControlCharactersToJSONSerialization() {
        for controlCharacter in UInt8(0x00)..<UInt8(0x20) {
            assertPassedToJSONSerialization(Data([0x22, 0x61, controlCharacter, 0x62, 0x22]), options: .fragmentsAllowed)
            assertPassedToJSONSerialization(
                Data([0x22, 0x5C, 0x6E, controlCharacter, 0x22]),
                options: .fragmentsAllowed
            )
        }
    }

    func testPassesInvalidUTF8ToJSONSerialization() {
        let invalidSequences: [[UInt8]] = [
            [0xFF], [0xFE], [0x80], [0xBF],
            [0xC0, 0xAF], [0xC1, 0xBF], [0xE0, 0x80, 0xAF], [0xF0, 0x80, 0x80, 0xAF],
            [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF],
            [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80],
            [0xC3], [0xE2, 0x82], [0xF0, 0x9F, 0x98],
            [0xC3, 0x41], [0xE2, 0x41, 0xAC],
        ]
        for sequence in invalidSequences {
            assertPassedToJSONSerialization(Data([0x22] + sequence + [0x22]), options: .fragmentsAllowed)
            assertPassedToJSONSerialization(Data([0x22, 0x5C, 0x6E] + sequence + [0x22]), options: .fragmentsAllowed)
            assertPassedToJSONSerialization(Data([0x7B, 0x22] + sequence + [0x22, 0x3A, 0x31, 0x7D]), options: [])
        }
    }

    func testPassesInvalidUnicodeEscapesToJSONSerialization() {
        let samples: [String] = [
            #""\ud83d""#, #""\ude00""#, #""\ud83dx""#, #""\ud83dA""#, #""\ud83d\ud83d""#, #""\ude00\ud83d""#,
        ]
        for sample in samples {
            assertPassedToJSONSerialization(Data(sample.utf8), options: .fragmentsAllowed)
        }
    }

    func testPassesNestingDeeperThanJSONSerializationAcceptsToIt() {
        for enclosingContainerCount in [513, 600, 100_000] {
            for sample in Self.nestedSamples(enclosingContainerCount: enclosingContainerCount) {
                assertPassedToJSONSerialization(Data(sample.utf8), options: [])
            }
        }
        for sample in [Self.arrays(514, ""), Self.arrays(513, "{}")] {
            assertPassedToJSONSerialization(Data(sample.utf8), options: [])
        }
    }

    func testPassesOtherEncodingsToJSONSerialization() {
        let sample = #"{"a":"ä€😀","b":[1,2.5,true,null]}"#
        let encodings: [String.Encoding] = [
            .utf16, .utf16BigEndian, .utf16LittleEndian, .utf32, .utf32BigEndian, .utf32LittleEndian,
        ]
        for encoding in encodings {
            assertPassedToJSONSerialization(sample.data(using: encoding)!, options: [])
        }
    }

    func testPassesFragmentsToJSONSerializationWhenFragmentsAreNotAllowed() {
        for sample in [#""aString""#, "42", "-1.5", "null", "true", "false"] {
            assertPassedToJSONSerialization(Data(sample.utf8), options: [])
        }
    }

    func testParsesItselfWithTheOptionsThatDoNotChangeTheContent() {
        let sample = Data(#"{"a":["b",1]}"#.utf8)
        for options: JSONSerialization.ReadingOptions in [.mutableContainers, .mutableLeaves, [.mutableContainers, .mutableLeaves, .fragmentsAllowed]] {
            assertParsedByContentParser(sample, options: options)
        }
    }

    func testPassesOptionsItDoesNotSupportToJSONSerialization() {
        assertPassedToJSONSerialization(Data(#"{a:1,b:'c',}"#.utf8), options: .json5Allowed)
        assertPassedToJSONSerialization(Data(#"{"a":1}"#.utf8), options: .json5Allowed)
        assertPassedToJSONSerialization(Data(#""a":1"#.utf8), options: [.json5Allowed, .topLevelDictionaryAssumed])
    }

    private func assertParsedByContentParser(
        _ data: Data,
        options: JSONSerialization.ReadingOptions,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotNil(
            ContentParser.parse(data: data, options: options),
            "ContentParser declined \(Self.describe(data))",
            file: file,
            line: line
        )
        assertBehavesLikeJSONSerialization(data, options: options, file: file, line: line)
    }

    private func assertPassedToJSONSerialization(
        _ data: Data,
        options: JSONSerialization.ReadingOptions,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(
            ContentParser.parse(data: data, options: options),
            "ContentParser parsed \(Self.describe(data))",
            file: file,
            line: line
        )
        assertBehavesLikeJSONSerialization(data, options: options, file: file, line: line)
    }

    private func assertBehavesLikeJSONSerialization(
        _ data: Data,
        options: JSONSerialization.ReadingOptions,
        file: StaticString,
        line: UInt
    ) {
        let expected = Result { JSON(try JSONSerialization.jsonObject(with: data, options: options)) }
        let actual = Result { try JSON(data: data, options: options) }
        switch (actual, expected) {
        case let (.success(actual), .success(expected)):
            assertIdentical(actual, expected, path: "$", data: data, file: file, line: line)
        case let (.failure(actual), .failure(expected)):
            let actual = actual as NSError
            let expected = expected as NSError
            XCTAssertEqual(actual.domain, expected.domain, "error domain for \(Self.describe(data))", file: file, line: line)
            XCTAssertEqual(actual.code, expected.code, "error code for \(Self.describe(data))", file: file, line: line)
            XCTAssertEqual(
                actual.userInfo as NSDictionary,
                expected.userInfo as NSDictionary,
                "error user info for \(Self.describe(data))",
                file: file,
                line: line
            )
        case (.success, .failure):
            XCTFail("parsed what JSONSerialization rejects: \(Self.describe(data))", file: file, line: line)
        case (.failure, .success):
            XCTFail("rejected what JSONSerialization parses: \(Self.describe(data))", file: file, line: line)
        }
    }

    // `JSON`'s equality treats `1` and `1.0` as well as canonically equivalent strings as equal, which would hide
    // differences callers can observe, so the content is compared by its exact representation instead.
    private func assertIdentical(
        _ actual: JSON,
        _ expected: JSON,
        path: String,
        data: Data,
        file: StaticString,
        line: UInt
    ) {
        let location = "at \(path) for \(Self.describe(data))"
        guard actual.type == expected.type else {
            XCTFail("type \(actual.type) instead of \(expected.type) \(location)", file: file, line: line)
            return
        }
        switch actual.type {
        case .number:
            let actualNumber = actual.numberValue
            let expectedNumber = expected.numberValue
            XCTAssertEqual(actualNumber is NSDecimalNumber, expectedNumber is NSDecimalNumber, "NSDecimalNumber \(location)", file: file, line: line)
            XCTAssertEqual(String(cString: actualNumber.objCType), String(cString: expectedNumber.objCType), "objCType \(location)", file: file, line: line)
            XCTAssertEqual(actualNumber.description, expectedNumber.description, "value \(location)", file: file, line: line)
            XCTAssertEqual(actualNumber.doubleValue.bitPattern, expectedNumber.doubleValue.bitPattern, "double value \(location)", file: file, line: line)
            XCTAssertEqual(actualNumber.int64Value, expectedNumber.int64Value, "integer value \(location)", file: file, line: line)
        case .string:
            XCTAssertEqual(Array(actual.stringValue.utf8), Array(expected.stringValue.utf8), "string \(location)", file: file, line: line)
        case .bool:
            XCTAssertEqual(actual.boolValue, expected.boolValue, "bool \(location)", file: file, line: line)
        case .array:
            let actualArray = actual.arrayValue
            let expectedArray = expected.arrayValue
            guard actualArray.count == expectedArray.count else {
                XCTFail("\(actualArray.count) instead of \(expectedArray.count) elements \(location)", file: file, line: line)
                return
            }
            for (index, element) in actualArray.enumerated() {
                assertIdentical(element, expectedArray[index], path: "\(path)[\(index)]", data: data, file: file, line: line)
            }
        case .dictionary:
            let actualDictionary = actual.dictionaryValue
            let expectedDictionary = expected.dictionaryValue
            let actualKeys = actualDictionary.keys.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
            let expectedKeys = expectedDictionary.keys.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
            guard actualKeys == expectedKeys else {
                XCTFail("keys \(actualDictionary.keys.sorted()) instead of \(expectedDictionary.keys.sorted()) \(location)", file: file, line: line)
                return
            }
            for (key, value) in actualDictionary {
                assertIdentical(value, expectedDictionary[key]!, path: "\(path).\(key)", data: data, file: file, line: line)
            }
        case .null, .unknown:
            break
        }
    }

    private static func nestedSamples(enclosingContainerCount: Int) -> [String] {
        let pairCount = enclosingContainerCount / 2
        let hasUnpairedContainer = !enclosingContainerCount.isMultiple(of: 2)
        return [
            arrays(enclosingContainerCount, "1"),
            arrays(enclosingContainerCount, #""s""#),
            arrays(enclosingContainerCount, "[]"),
            arrays(enclosingContainerCount, "{}"),
            arrays(enclosingContainerCount - 1, "[[],1]"),
            objects(enclosingContainerCount, "1"),
            objects(enclosingContainerCount, "{}"),
            String(repeating: #"[{"a":"#, count: pairCount)
                + (hasUnpairedContainer ? "[1]" : "1")
                + String(repeating: "}]", count: pairCount),
            String(repeating: #"{"a":["#, count: pairCount)
                + (hasUnpairedContainer ? #"{"a":true}"# : "true")
                + String(repeating: "]}", count: pairCount),
        ]
    }

    private static func arrays(_ count: Int, _ innermostValue: String) -> String {
        String(repeating: "[", count: count) + innermostValue + String(repeating: "]", count: count)
    }

    private static func objects(_ count: Int, _ innermostValue: String) -> String {
        String(repeating: #"{"a":"#, count: count) + innermostValue + String(repeating: "}", count: count)
    }

    private static func describe(_ data: Data) -> String {
        let text = String(decoding: data.prefix(80), as: UTF8.self).debugDescription
        return data.count > 80 ? "\(text)… (\(data.count) bytes)" : text
    }

    private static func randomNumber(using generator: inout SplitMix64) -> String {
        func digits(_ count: Int) -> String {
            String((0..<count).map { _ in Character(String(Int.random(in: 0...9, using: &generator))) })
        }
        var number = Bool.random(using: &generator) ? "-" : ""
        let integerDigitCount = Int.random(in: 1...22, using: &generator)
        if integerDigitCount == 1 || Int.random(in: 0..<4, using: &generator) == 0 {
            number += "0"
        } else {
            number += String(Int.random(in: 1...9, using: &generator)) + digits(integerDigitCount - 1)
        }
        if Bool.random(using: &generator) {
            number += "." + digits(Int.random(in: 1...22, using: &generator))
        }
        if Int.random(in: 0..<3, using: &generator) == 0 {
            number += ["e", "E"].randomElement(using: &generator)! + ["", "+", "-"].randomElement(using: &generator)!
            number += String(Int.random(in: 0...330, using: &generator))
        }
        return number
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
