//  ContentParser.swift
//
//  Parses JSON data straight into `Content`.
//
//  `JSONSerialization` produces a tree of Foundation objects, which then has to be walked a second time to build the
//  `Content` tree `JSON` stores. For large documents that second walk costs several times the parse itself, so this
//  parser skips the intermediate representation.

import Foundation

internal enum ContentParser {
    internal static func parse(
        data: Data,
        options: JSONSerialization.ReadingOptions
    ) throws -> Content {
        try data.withUnsafeBytes { buffer -> Content in
            var parser = Parser(bytes: buffer.bindMemory(to: UInt8.self), options: options)

            return try parser.parseDocument()
        }
    }

    fileprivate struct Parser {
        fileprivate let bytes: UnsafeBufferPointer<UInt8>
        fileprivate let options: JSONSerialization.ReadingOptions
        fileprivate var index: Int = 0

        fileprivate mutating func parseDocument() throws -> Content {
            self.skipWhitespace()
            let content = try self.parseValue()
            self.skipWhitespace()
            guard self.index == self.bytes.count else {
                throw SwiftyJSONError.invalidJSON
            }
            if !self.options.contains(.allowFragments) {
                switch content {
                    case .array, .dictionary:
                        break
                    default:
                        throw SwiftyJSONError.invalidJSON
                }
            }

            return content
        }

        private mutating func parseValue() throws -> Content {
            guard self.index < self.bytes.count else {
                throw SwiftyJSONError.invalidJSON
            }

            switch self.bytes[self.index] {
                case UInt8(ascii: "{"):
                    return try self.parseObject()
                case UInt8(ascii: "["):
                    return try self.parseArray()
                case UInt8(ascii: "\""):
                    return .string(try self.parseString())
                case UInt8(ascii: "t"):
                    try self.expect("true")

                    return .bool(true)
                case UInt8(ascii: "f"):
                    try self.expect("false")

                    return .bool(false)
                case UInt8(ascii: "n"):
                    try self.expect("null")

                    return .null
                default:
                    return .number(try self.parseNumber())
            }
        }

        private mutating func parseObject() throws -> Content {
            self.index += 1 // consume `{`
            var dictionary: [String: Content] = [:]
            self.skipWhitespace()
            if self.peek() == UInt8(ascii: "}") {
                self.index += 1

                return .dictionary(dictionary)
            }

            while true {
                self.skipWhitespace()
                guard self.peek() == UInt8(ascii: "\"") else {
                    throw SwiftyJSONError.invalidJSON
                }
                let key = try self.parseString()
                self.skipWhitespace()
                guard self.peek() == UInt8(ascii: ":") else {
                    throw SwiftyJSONError.invalidJSON
                }
                self.index += 1
                self.skipWhitespace()
                // `JSONSerialization` keeps the first of two equal keys, so put a replaced value back.
                if let previousValue = dictionary.updateValue(try self.parseValue(), forKey: key) {
                    dictionary[key] = previousValue
                }
                self.skipWhitespace()
                switch self.peek() {
                    case UInt8(ascii: ","):
                        self.index += 1
                    case UInt8(ascii: "}"):
                        self.index += 1

                        return .dictionary(dictionary)
                    default:
                        throw SwiftyJSONError.invalidJSON
                }
            }
        }

        private mutating func parseArray() throws -> Content {
            self.index += 1 // consume `[`
            var array: [Content] = []
            self.skipWhitespace()
            if self.peek() == UInt8(ascii: "]") {
                self.index += 1

                return .array(array)
            }

            while true {
                self.skipWhitespace()
                array.append(try self.parseValue())
                self.skipWhitespace()
                switch self.peek() {
                    case UInt8(ascii: ","):
                        self.index += 1
                    case UInt8(ascii: "]"):
                        self.index += 1

                        return .array(array)
                    default:
                        throw SwiftyJSONError.invalidJSON
                }
            }
        }

        private mutating func parseString() throws -> String {
            self.index += 1 // consume the opening quote
            let start = self.index
            // Scan for a string that needs no unescaping, which is the overwhelmingly common case, and build it in
            // one go from the raw bytes.
            while self.index < self.bytes.count {
                let byte = self.bytes[self.index]
                if byte == UInt8(ascii: "\"") {
                    let string = String(
                        decoding: UnsafeBufferPointer(rebasing: self.bytes[start..<self.index]),
                        as: UTF8.self
                    )
                    self.index += 1

                    return string
                }
                if byte == UInt8(ascii: "\\") {
                    return try self.parseEscapedString(from: start)
                }
                self.index += 1
            }

            throw SwiftyJSONError.invalidJSON
        }

        private mutating func parseEscapedString(from start: Int) throws -> String {
            var utf8: [UInt8] = Array(UnsafeBufferPointer(rebasing: self.bytes[start..<self.index]))
            while self.index < self.bytes.count {
                let byte = self.bytes[self.index]
                if byte == UInt8(ascii: "\"") {
                    self.index += 1

                    return String(decoding: utf8, as: UTF8.self)
                }
                guard byte == UInt8(ascii: "\\") else {
                    utf8.append(byte)
                    self.index += 1

                    continue
                }

                self.index += 1
                guard self.index < self.bytes.count else {
                    throw SwiftyJSONError.invalidJSON
                }
                let escape = self.bytes[self.index]
                self.index += 1
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
                        try self.appendUnicodeEscape(to: &utf8)
                    default:
                        throw SwiftyJSONError.invalidJSON
                }
            }

            throw SwiftyJSONError.invalidJSON
        }

        private mutating func appendUnicodeEscape(to utf8: inout [UInt8]) throws {
            var scalarValue = UInt32(try self.parseHexQuad())
            if scalarValue >= 0xD800, scalarValue <= 0xDBFF {
                // A high surrogate is only valid when followed by the low surrogate it pairs with.
                guard
                    self.index + 1 < self.bytes.count,
                    self.bytes[self.index] == UInt8(ascii: "\\"),
                    self.bytes[self.index + 1] == UInt8(ascii: "u")
                else {
                    throw SwiftyJSONError.invalidJSON
                }
                self.index += 2
                let lowSurrogate = UInt32(try self.parseHexQuad())
                guard lowSurrogate >= 0xDC00, lowSurrogate <= 0xDFFF else {
                    throw SwiftyJSONError.invalidJSON
                }
                scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (lowSurrogate - 0xDC00)
            }
            guard let scalar = Unicode.Scalar(scalarValue) else {
                throw SwiftyJSONError.invalidJSON
            }
            UTF8.encode(scalar) { utf8.append($0) }
        }

        private mutating func parseHexQuad() throws -> UInt16 {
            guard self.index + 4 <= self.bytes.count else {
                throw SwiftyJSONError.invalidJSON
            }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let byte = self.bytes[self.index]
                let digit: UInt16
                switch byte {
                    case UInt8(ascii: "0")...UInt8(ascii: "9"):
                        digit = UInt16(byte - UInt8(ascii: "0"))
                    case UInt8(ascii: "a")...UInt8(ascii: "f"):
                        digit = UInt16(byte - UInt8(ascii: "a")) + 10
                    case UInt8(ascii: "A")...UInt8(ascii: "F"):
                        digit = UInt16(byte - UInt8(ascii: "A")) + 10
                    default:
                        throw SwiftyJSONError.invalidJSON
                }
                value = value << 4 | digit
                self.index += 1
            }

            return value
        }

        private mutating func parseNumber() throws -> NSNumber {
            let start = self.index
            var isInteger = true
            if self.peek() == UInt8(ascii: "-") {
                self.index += 1
            }
            while self.index < self.bytes.count {
                switch self.bytes[self.index] {
                    case UInt8(ascii: "0")...UInt8(ascii: "9"):
                        self.index += 1
                    case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"),
                         UInt8(ascii: "+"), UInt8(ascii: "-"):
                        isInteger = false
                        self.index += 1
                    default:
                        return try self.makeNumber(from: start, isInteger: isInteger)
                }
            }

            return try self.makeNumber(from: start, isInteger: isInteger)
        }

        private func makeNumber(from start: Int, isInteger: Bool) throws -> NSNumber {
            guard start < self.index else {
                throw SwiftyJSONError.invalidJSON
            }
            let digits = UnsafeBufferPointer(rebasing: self.bytes[start..<self.index])
            let text = String(decoding: digits, as: UTF8.self)
            if isInteger {
                if let integer = Int64(text) {
                    return NSNumber(value: integer)
                }
                // Integers beyond `Int64` keep their precision the way `JSONSerialization` reports them.
                if let unsignedInteger = UInt64(text) {
                    return NSNumber(value: unsignedInteger)
                }

                return NSDecimalNumber(string: text)
            }
            guard let double = Double(text) else {
                throw SwiftyJSONError.invalidJSON
            }

            return NSNumber(value: double)
        }

        private mutating func expect(_ literal: StaticString) throws {
            guard self.index + literal.utf8CodeUnitCount <= self.bytes.count else {
                throw SwiftyJSONError.invalidJSON
            }
            for offset in 0..<literal.utf8CodeUnitCount {
                guard self.bytes[self.index + offset] == literal.utf8Start[offset] else {
                    throw SwiftyJSONError.invalidJSON
                }
            }
            self.index += literal.utf8CodeUnitCount
        }

        private func peek() -> UInt8? {
            self.index < self.bytes.count ? self.bytes[self.index] : nil
        }

        private mutating func skipWhitespace() {
            while self.index < self.bytes.count {
                switch self.bytes[self.index] {
                    case 0x20, 0x09, 0x0A, 0x0D:
                        self.index += 1
                    default:
                        return
                }
            }
        }
    }
}
