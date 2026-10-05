//  ContentParser.swift
//
//  Parses UTF-8 JSON data straight into `Content`.
//
//  `JSONSerialization` produces a tree of Foundation objects, which then has to be walked a second time to build the
//  `Content` tree `JSON` stores. For large documents that second walk costs several times the parse itself, so this
//  parser skips the intermediate representation. It declines every document it cannot parse exactly like
//  `JSONSerialization`, so that the caller can leave those to `JSONSerialization`.

import Foundation

internal enum ContentParser {

    private static let supportedOptions: JSONSerialization.ReadingOptions = [
        .mutableContainers, .mutableLeaves, .fragmentsAllowed,
    ]

    // `JSONSerialization` rejects any value enclosed by this many containers, though it accepts an empty container
    // at that depth.
    private static let maximumEnclosingContainerCount = 513

    internal static func parse(data: Data, options: JSONSerialization.ReadingOptions) -> Content? {
        guard supportedOptions.isSuperset(of: options) else {
            return nil
        }

        return data.withUnsafeBytes { buffer in
            var parser = Parser(
                bytes: buffer.bindMemory(to: UInt8.self),
                allowsFragments: options.contains(.fragmentsAllowed)
            )

            return try? parser.parseDocument()
        }
    }

    private struct Declined: Error {}

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        let allowsFragments: Bool
        var index = 0
        var enclosingContainerCount = 0

        mutating func parseDocument() throws -> Content {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                index = 3
            }
            skipWhitespace()
            let content = try parseValue()
            skipWhitespace()
            guard index == bytes.count else {
                throw Declined()
            }
            if !allowsFragments {
                switch content {
                case .array, .dictionary:
                    break
                default:
                    throw Declined()
                }
            }

            return content
        }

        private mutating func parseValue() throws -> Content {
            guard let byte = peek(), enclosingContainerCount < ContentParser.maximumEnclosingContainerCount else {
                throw Declined()
            }
            switch byte {
            case UInt8(ascii: "{"):
                return try parseObject()
            case UInt8(ascii: "["):
                return try parseArray()
            case UInt8(ascii: "\""):
                return .string(try parseString())
            case UInt8(ascii: "t"):
                try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return .number(try parseNumber())
            default:
                throw Declined()
            }
        }

        private mutating func parseObject() throws -> Content {
            enterContainer()
            defer { enclosingContainerCount -= 1 }
            var dictionary: [String: Content] = [:]
            skipWhitespace()
            if peek() == UInt8(ascii: "}") {
                index += 1
                return .dictionary(dictionary)
            }

            while true {
                skipWhitespace()
                guard peek() == UInt8(ascii: "\"") else {
                    throw Declined()
                }
                let key = try parseString()
                skipWhitespace()
                guard peek() == UInt8(ascii: ":") else {
                    throw Declined()
                }
                index += 1
                skipWhitespace()
                // `JSONSerialization` keeps the first of two equal keys, so put a replaced value back.
                if let previousValue = dictionary.updateValue(try parseValue(), forKey: key) {
                    dictionary[key] = previousValue
                }
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","):
                    index += 1
                case UInt8(ascii: "}"):
                    index += 1
                    return .dictionary(dictionary)
                default:
                    throw Declined()
                }
            }
        }

        private mutating func parseArray() throws -> Content {
            enterContainer()
            defer { enclosingContainerCount -= 1 }
            var array: [Content] = []
            skipWhitespace()
            if peek() == UInt8(ascii: "]") {
                index += 1
                return .array(array)
            }

            while true {
                skipWhitespace()
                array.append(try parseValue())
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","):
                    index += 1
                case UInt8(ascii: "]"):
                    index += 1
                    return .array(array)
                default:
                    throw Declined()
                }
            }
        }

        private mutating func enterContainer() {
            index += 1
            enclosingContainerCount += 1
        }

        private mutating func parseString() throws -> String {
            index += 1
            let start = index
            var isASCII = true
            // Strings without escapes are by far the most common, so they are built in one go from the raw bytes.
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    let string = try makeString(UnsafeBufferPointer(rebasing: bytes[start..<index]), isASCII: isASCII)
                    index += 1
                    return string
                case UInt8(ascii: "\\"):
                    return try parseEscapedString(from: start, isASCII: isASCII)
                case ..<0x20:
                    throw Declined()
                case 0x80...:
                    isASCII = false
                default:
                    break
                }
                index += 1
            }

            throw Declined()
        }

        private mutating func parseEscapedString(from start: Int, isASCII: Bool) throws -> String {
            var utf8 = Array(UnsafeBufferPointer(rebasing: bytes[start..<index]))
            var isASCII = isASCII
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return try makeString(utf8, isASCII: isASCII)
                case UInt8(ascii: "\\"):
                    try appendEscapeSequence(to: &utf8)
                case ..<0x20:
                    throw Declined()
                case 0x80...:
                    isASCII = false
                    utf8.append(byte)
                default:
                    utf8.append(byte)
                }
            }

            throw Declined()
        }

        private func makeString<UTF8Bytes: Collection>(
            _ utf8: UTF8Bytes,
            isASCII: Bool
        ) throws -> String where UTF8Bytes.Element == UInt8 {
            // `String(decoding:as:)` would silently repair invalid UTF-8, which `JSONSerialization` rejects.
            if !isASCII {
                var iterator = utf8.makeIterator()
                var parser = Unicode.UTF8.ForwardParser()
                validation: while true {
                    switch parser.parseScalar(from: &iterator) {
                    case .valid:
                        continue
                    case .emptyInput:
                        break validation
                    case .error:
                        throw Declined()
                    }
                }
            }

            return String(decoding: utf8, as: UTF8.self)
        }

        private mutating func appendEscapeSequence(to utf8: inout [UInt8]) throws {
            guard let escape = peek() else {
                throw Declined()
            }
            index += 1
            switch escape {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
                utf8.append(escape)
            case UInt8(ascii: "b"):
                utf8.append(0x08)
            case UInt8(ascii: "f"):
                utf8.append(0x0C)
            case UInt8(ascii: "n"):
                utf8.append(0x0A)
            case UInt8(ascii: "r"):
                utf8.append(0x0D)
            case UInt8(ascii: "t"):
                utf8.append(0x09)
            case UInt8(ascii: "u"):
                try appendUnicodeEscape(to: &utf8)
            default:
                throw Declined()
            }
        }

        private mutating func appendUnicodeEscape(to utf8: inout [UInt8]) throws {
            var scalarValue = UInt32(try parseHexQuad())
            if (0xD800...0xDBFF).contains(scalarValue) {
                guard
                    index + 1 < bytes.count,
                    bytes[index] == UInt8(ascii: "\\"),
                    bytes[index + 1] == UInt8(ascii: "u")
                else {
                    throw Declined()
                }
                index += 2
                let lowSurrogate = UInt32(try parseHexQuad())
                guard (0xDC00...0xDFFF).contains(lowSurrogate) else {
                    throw Declined()
                }
                scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (lowSurrogate - 0xDC00)
            }
            guard let scalar = Unicode.Scalar(scalarValue) else {
                throw Declined()
            }
            UTF8.encode(scalar) { utf8.append($0) }
        }

        private mutating func parseHexQuad() throws -> UInt16 {
            guard index + 4 <= bytes.count else {
                throw Declined()
            }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt16
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    digit = UInt16(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"):
                    digit = UInt16(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"):
                    digit = UInt16(byte - UInt8(ascii: "A")) + 10
                default:
                    throw Declined()
                }
                value = value << 4 | digit
                index += 1
            }

            return value
        }

        private mutating func parseNumber() throws -> NSNumber {
            let start = index
            let isNegative = peek() == UInt8(ascii: "-")
            if isNegative {
                index += 1
            }
            let integerStart = index
            let integerDigitCount = skipDigits()
            let hasLeadingZero = integerDigitCount > 0 && bytes[integerStart] == UInt8(ascii: "0")
            guard integerDigitCount > 0, !hasLeadingZero || integerDigitCount == 1 else {
                throw Declined()
            }
            var fractionDigitCount = 0
            if peek() == UInt8(ascii: ".") {
                index += 1
                fractionDigitCount = skipDigits()
                guard fractionDigitCount > 0 else {
                    throw Declined()
                }
            }
            var hasExponent = false
            if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
                hasExponent = true
                index += 1
                if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") {
                    index += 1
                }
                guard skipDigits() > 0 else {
                    throw Declined()
                }
            }
            let text = UnsafeBufferPointer(rebasing: bytes[start..<index])

            if fractionDigitCount == 0 && !hasExponent && integerDigitCount <= 18 {
                var integer: Int64 = 0
                for digit in bytes[integerStart..<(integerStart + integerDigitCount)] {
                    integer = integer * 10 + Int64(digit - UInt8(ascii: "0"))
                }
                return NSNumber(value: isNegative ? -integer : integer)
            }
            let significantDigitCount = (hasLeadingZero ? 0 : integerDigitCount) + fractionDigitCount
            if fractionDigitCount > 0 && !hasExponent && significantDigitCount <= 15,
               let double = Double(String(decoding: text, as: UTF8.self)) {
                return NSNumber(value: double)
            }
            // Beyond these, `JSONSerialization` switches to `NSDecimalNumber` and handles overflow in ways that
            // differ by sign and representation, so it parses the remaining numbers itself.
            guard let number = try JSONSerialization.jsonObject(with: Data(text), options: .fragmentsAllowed)
                as? NSNumber
            else {
                throw Declined()
            }

            return number
        }

        private mutating func skipDigits() -> Int {
            let start = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }

            return index - start
        }

        private mutating func expect(_ literal: StaticString) throws {
            guard index + literal.utf8CodeUnitCount <= bytes.count else {
                throw Declined()
            }
            for offset in 0..<literal.utf8CodeUnitCount where bytes[index + offset] != literal.utf8Start[offset] {
                throw Declined()
            }
            index += literal.utf8CodeUnitCount
        }

        private func peek() -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                default:
                    return
                }
            }
        }
    }
}
