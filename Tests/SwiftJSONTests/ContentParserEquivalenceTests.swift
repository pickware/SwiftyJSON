//  ContentParserEquivalenceTests.swift
//
//  Checks that parsing straight into `Content` produces exactly what `JSONSerialization` followed by
//  `JSON(jsonObject:)` produced before, including the concrete `NSNumber` types.

import XCTest
@testable import SwiftyJSON

class ContentParserEquivalenceTests: XCTestCase {

    private let validSamples: [String] = [
        #"{"a":1,"b":-2,"c":1.5,"d":-0.0,"e":1e3,"f":1E-3,"g":-1.2e+10}"#,
        #"{"max":9223372036854775807,"beyondInt64":9223372036854775808,"min":-9223372036854775808}"#,
        #"{"t":true,"f":false,"n":null}"#,
        #"{"escapes":"a\"b\\c\/d\be\ff\ng\rh\ti"}"#,
        #"{"unicodeEscapes":"ä€😀"}"#,
        #"{"literalUnicode":"ä€😀"}"#,
        #"{"äKey":"escaped key"}"#,
        #"{"empty":{},"emptyArray":[],"nested":{"a":[{"b":[1,2,[3]]}]}}"#,
        #"{"duplicate":1,"duplicate":2}"#,
        #"[1,"two",3.0,null,true,{"k":"v"},[]]"#,
        "  {\"padded\" : [ 1 , 2 ] }  ",
        "{\"whitespace\":\t[\n1,\r2 ]\n}",
        #""justAString""#,
        #"42"#,
        #"null"#,
    ]

    func testProducesTheSameContentAsJSONSerialization() throws {
        for sample in validSamples {
            let data = Data(sample.utf8)
            let viaSerialization = JSON(try JSONSerialization.jsonObject(with: data, options: .allowFragments))
            let viaParser = try JSON(data: data, options: .allowFragments)
            XCTAssertEqual(viaParser, viaSerialization, "mismatch for \(sample)")
        }
    }

    /// `JSON`'s equality compares `NSNumber` values, so `1` and `1.0` compare equal. Numbers are therefore compared
    /// by their concrete type as well, which is what callers reading `intValue` or `doubleValue` depend on.
    func testPreservesTheNumberTypesJSONSerializationProduces() throws {
        for sample in validSamples {
            let data = Data(sample.utf8)
            let viaSerialization = JSON(try JSONSerialization.jsonObject(with: data, options: .allowFragments))
            let viaParser = try JSON(data: data, options: .allowFragments)
            assertNumberTypesAreEqual(viaParser, viaSerialization, path: "$", sample: sample)
        }
    }

    func testRejectsInvalidDocuments() {
        let invalidSamples: [String] = [
            "{", "[", #"{"a"}"#, #"{"a":}"#, "[1,]", "{,}", "tru", "nul", "\"unterminated",
            #"{"a":1}trailing"#, "[1 2]", "",
        ]
        for sample in invalidSamples {
            XCTAssertThrowsError(
                try JSON(data: Data(sample.utf8), options: .allowFragments),
                "expected a throw for \(sample)"
            )
        }
    }

    func testRejectsFragmentsWhenFragmentsAreNotAllowed() {
        for sample in [#""aString""#, "42", "null", "true"] {
            XCTAssertThrowsError(
                try JSON(data: Data(sample.utf8)),
                "expected a throw for the fragment \(sample)"
            )
        }
    }

    private func assertNumberTypesAreEqual(_ lhs: JSON, _ rhs: JSON, path: String, sample: String) {
        switch (lhs.type, rhs.type) {
        case (.number, .number):
            XCTAssertEqual(
                String(cString: lhs.numberValue.objCType),
                String(cString: rhs.numberValue.objCType),
                "number type differs at \(path) for \(sample)"
            )
        case (.array, .array):
            for (index, element) in lhs.arrayValue.enumerated() {
                assertNumberTypesAreEqual(element, rhs[index], path: "\(path)[\(index)]", sample: sample)
            }
        case (.dictionary, .dictionary):
            for (key, value) in lhs.dictionaryValue {
                assertNumberTypesAreEqual(value, rhs[key], path: "\(path).\(key)", sample: sample)
            }
        default:
            XCTAssertEqual(lhs.type, rhs.type, "type differs at \(path) for \(sample)")
        }
    }
}
