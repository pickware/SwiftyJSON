//  SerializedObjectConversionTests.swift
//
//  Checks that `JSON(data:)` builds exactly the `JSON` that `JSON(_:)` builds from the result of
//  `JSONSerialization.jsonObject(with:options:)`, which is what `JSON(data:)` did before it converted that result
//  itself: the same content down to the concrete `NSNumber` classes, types and values and the bytes of every string,
//  the same `error`, and the same error thrown for data `JSONSerialization` rejects.

import XCTest
import SwiftyJSON

class SerializedObjectConversionTests: XCTestCase {

    func testConvertsEveryKindOfValue() {
        let samples: [String] = [
            #"{"string":"a","number":1,"double":1.5,"true":true,"false":false,"null":null,"object":{},"array":[]}"#,
            #"[1,"two",3.0,null,true,false,{"k":"v"},[],[[]],{"a":{"b":{"c":[1,[2,[3]]]}}}]"#,
            #"{"zero":0,"one":1,"zeroDouble":0.0,"oneDouble":1.0,"t":true,"f":false,"list":[0,1,true,false,0.0,1.0]}"#,
            #"{"negativeZero":-0,"negativeZeroDouble":-0.0,"negativeInfinity":-1e400,"tiny":5e-324,"underflow":1e-400}"#,
            #"{"max":9223372036854775807,"min":-9223372036854775808,"beyondInt64":9223372036854775808}"#,
            #"{"beyondUInt64":18446744073709551616,"long":0.123456789012345678,"longer":123456789012345678901234567890}"#,
            #"{"escapes":"a\"b\\c\/d\be\ff\ng\rh\ti","unicode":"ä€😀","literal":"ä€😀"}"#,
            #"{"äKey":1,"äKey2":2,"":"empty key","a\u0000b":"nul in key"}"#,
            #"{"duplicate":1,"duplicate":2}"#,
        ]
        for sample in samples {
            assertConvertsLikeJSONSerialization(Data(sample.utf8), options: [])
        }
    }

    func testConvertsFragments() {
        for sample in [#""aString""#, "42", "-1.5", "1e400", "null", "true", "false", #""""#] {
            assertConvertsLikeJSONSerialization(Data(sample.utf8), options: .fragmentsAllowed)
        }
    }

    func testConvertsWithEveryReadingOption() {
        let sample = Data(#"{"a":["b",1,true,null,{"c":[2.5]}],"d":"e"}"#.utf8)
        let optionSets: [JSONSerialization.ReadingOptions] = [
            [], .mutableContainers, .mutableLeaves, .fragmentsAllowed,
            [.mutableContainers, .mutableLeaves, .fragmentsAllowed],
        ]
        for options in optionSets {
            assertConvertsLikeJSONSerialization(sample, options: options)
            assertConvertsLikeJSONSerialization(Data("[\(Self.mixedValues(count: 1_000))]".utf8), options: options)
        }
    }

    func testKeepsOneOfSeveralCanonicallyEquivalentKeysWithItsOwnValue() throws {
        // These spellings are different bytes, so `JSONSerialization` keeps each as a key of its own, but they are
        // equal as `String`s, so only one of them can remain. Which one `JSON(_:)` keeps depends on Swift's
        // per-process hash seed, so the conversion has to keep one of them together with its own value.
        let equivalentKeys = ["\u{C5}", "A\u{30A}", "\u{212B}"]
        var generator = SplitMix64(seed: 0xC0FFEE)
        for _ in 0..<200 {
            let keys = Array(equivalentKeys.shuffled(using: &generator).prefix(Int.random(in: 2...3, using: &generator)))
            let fillerKeys = (0..<Int.random(in: 0...20, using: &generator)).map { "filler\($0)" }
            let members = keys.map { #""\#($0)":"\#($0)""# } + fillerKeys.map { #""\#($0)":"\#($0)""# }
            let object = "{\(members.shuffled(using: &generator).joined(separator: ","))}"
            for data in [Data(object.utf8), Data("[\(Array(repeating: object, count: 300).joined(separator: ","))]".utf8)] {
                let json = try JSON(data: data)
                for dictionary in json.type == .array ? json.arrayValue : [json] {
                    let entries = dictionary.dictionaryValue
                    XCTAssertEqual(entries.count, fillerKeys.count + 1, "entries for \(object.debugDescription)")
                    for (key, value) in entries {
                        XCTAssertEqual(Array(value.stringValue.utf8), Array(key.utf8), "value of \(key.debugDescription) in \(object.debugDescription)")
                    }
                    let keptKey = entries.keys.first { !$0.hasPrefix("filler") }
                    XCTAssertTrue(keys.contains { Array($0.utf8) == keptKey.map { Array($0.utf8) } }, "kept \(keptKey.debugDescription) of \(object.debugDescription)")
                }
            }
        }
    }

    func testConvertsArraysAroundTheSizeConvertedInParallel() {
        for count in [0, 1, 255, 256, 257, 1_000, 10_007] {
            assertConvertsLikeJSONSerialization(Data("[\(Self.mixedValues(count: count))]".utf8), options: [])
            assertConvertsLikeJSONSerialization(
                Data(#"{"before":[\#(Self.mixedValues(count: count))],"after":[\#(Self.mixedValues(count: count))]}"#.utf8),
                options: []
            )
        }
    }

    func testConvertsLargeArraysNestedInLargeArrays() {
        let inner = "[\(Self.mixedValues(count: 300))]"
        let middle = "[\(Array(repeating: inner, count: 300).joined(separator: ","))]"
        assertConvertsLikeJSONSerialization(Data(middle.utf8), options: [])
        assertConvertsLikeJSONSerialization(Data("[\(middle),\(middle)]".utf8), options: [])
        assertConvertsLikeJSONSerialization(Data(#"{"a":{"b":\#(middle)}}"#.utf8), options: [])
    }

    func testConvertsAJSONAPIDocument() {
        var generator = SplitMix64(seed: 0x5EED)
        let resources = (0..<5_000).map { Self.resource(index: $0, using: &generator) }
        let document = #"{"data":[\#(resources.prefix(100).joined(separator: ","))],"included":[\#(resources.dropFirst(100).joined(separator: ","))],"links":{"self":"https://shop/api"},"meta":{"total":100}}"#
        assertConvertsLikeJSONSerialization(Data(document.utf8), options: [])
    }

    func testThrowsWhatJSONSerializationThrows() {
        let samples: [Data] = [
            Data(), Data("{".utf8), Data(#"{"a":}"#.utf8), Data("[1,]".utf8), Data("01".utf8), Data([0x22, 0xFF, 0x22]),
            Data((String(repeating: "[", count: 600) + String(repeating: "]", count: 600)).utf8),
        ]
        for sample in samples {
            assertConvertsLikeJSONSerialization(sample, options: .fragmentsAllowed)
        }
        assertConvertsLikeJSONSerialization(Data("42".utf8), options: [])
    }

    private func assertConvertsLikeJSONSerialization(
        _ data: Data,
        options: JSONSerialization.ReadingOptions,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = Result { JSON(try JSONSerialization.jsonObject(with: data, options: options)) }
        let actual = Result { try JSON(data: data, options: options) }
        switch (actual, expected) {
        case let (.success(actual), .success(expected)):
            XCTAssertEqual(actual.error, expected.error, "error for \(Self.describe(data))", file: file, line: line)
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
            XCTFail("converted what JSONSerialization rejects: \(Self.describe(data))", file: file, line: line)
        case (.failure, .success):
            XCTFail("threw for what JSONSerialization parses: \(Self.describe(data))", file: file, line: line)
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
            XCTAssertTrue(type(of: actualNumber) == type(of: expectedNumber), "number class \(location)", file: file, line: line)
            XCTAssertEqual(String(cString: actualNumber.objCType), String(cString: expectedNumber.objCType), "objCType \(location)", file: file, line: line)
            XCTAssertEqual(actualNumber.description, expectedNumber.description, "value \(location)", file: file, line: line)
            XCTAssertEqual(actualNumber.doubleValue.bitPattern, expectedNumber.doubleValue.bitPattern, "double value \(location)", file: file, line: line)
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
                XCTFail("keys \(actualKeys) instead of \(expectedKeys) \(location)", file: file, line: line)
                return
            }
            for (key, value) in actualDictionary {
                assertIdentical(value, expectedDictionary[key]!, path: "\(path).\(key)", data: data, file: file, line: line)
            }
        case .null, .unknown:
            break
        }
    }

    private static func mixedValues(count: Int) -> String {
        let values = [
            "1", "-2.5", "true", "false", "null", #""text""#, #""ä€😀""#, "{}", "[]", #"{"k":[1,{"n":null}]}"#,
            "0.123456789012345678", "1e3", "0", "1",
        ]
        return (0..<count).map { values[$0 % values.count] }.joined(separator: ",")
    }

    private static func resource(index: Int, using generator: inout SplitMix64) -> String {
        func id() -> String {
            String(format: "%016llx%016llx", generator.next(), generator.next())
        }
        let type = ["product", "order_line_item", "pickware_erp_stock", "pickware_erp_bin_location"][index % 4]
        let price = Double(Int.random(in: 0...99_999, using: &generator)) / 100
        let stocks = (0..<3).map { _ in #"{"type":"pickware_erp_stock","id":"\#(id())"}"# }.joined(separator: ",")
        return #"{"id":"\#(id())","type":"\#(type)","attributes":{"name":"Produkt \#(index) – Größe M","productNumber":"SW\#(index)","quantity":\#(index % 500),"unitPrice":\#(price),"active":\#(index % 2 == 0),"description":null,"customFields":{"flag":true,"empty":null}},"relationships":{"product":{"data":{"type":"product","id":"\#(id())"}},"stocks":{"data":[\#(stocks)]}}}"#
    }

    private static func describe(_ data: Data) -> String {
        let text = String(decoding: data.prefix(80), as: UTF8.self).debugDescription
        return data.count > 80 ? "\(text)… (\(data.count) bytes)" : text
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
