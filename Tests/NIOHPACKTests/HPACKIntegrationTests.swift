//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIOCore
@testable import NIOHPACK

class HPACKIntegrationTests : XCTestCase {
    private let hpackTestsURL: URL = {
        let myURL = URL(fileURLWithPath: #filePath, isDirectory: false)
        let result: URL
        if #available(OSX 10.11, iOS 9.0, *) {
            result = URL(fileURLWithPath: "../hpack-test-case", isDirectory: true, relativeTo: myURL).absoluteURL
        } else {
            // Fallback on earlier versions
            result = URL(string: "../hpack-test-case", relativeTo: myURL)!.absoluteURL
        }
        return result
    }()
    
    private enum TestType : String {
        case encoding = "raw-data"
        
        case swiftNIOPlain = "swift-nio-hpack-plain-text"
        case swiftNIOHuffman = "swift-nio-hpack-huffman"
        case node = "node-http2-hpack"
        case python = "python-hpack"
        case go = "go-hpack"
        
        case nghttp2
        case nghttp2ChangeTableSize = "nghttp2-change-table-size"
        case nghttp2LargeTables = "nghttp2-16384-4096"
        
        case haskellStatic = "haskell-http2-static"
        case haskellStaticHuffman = "haskell-http2-static-huffman"
        case haskellNaive = "haskell-http2-naive"
        case haskellNaiveHuffman = "haskell-http2-naive-huffman"
        case haskellLinear = "haskell-http2-linear"
        case haskellLinearHuffman = "haskell-http2-linear-huffman"
        
        static let allCases: [TestType] = [
            .encoding, .swiftNIOPlain, .swiftNIOHuffman, .node, .python, .go,
            .nghttp2, .nghttp2ChangeTableSize, .nghttp2LargeTables,
            .haskellStatic, .haskellStaticHuffman, .haskellNaive, .haskellNaiveHuffman,
            .haskellLinear, .haskellLinearHuffman
        ]
    }
    
    private func getSourceURL(for type: TestType) -> URL {
        return self.hpackTestsURL.appendingPathComponent(type.rawValue, isDirectory: true).absoluteURL
    }
    
    private func loadStories(for test: TestType) -> [HPACKStory] {
        let url = self.getSourceURL(for: test)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []).sorted(by: {$0.lastPathComponent < $1.lastPathComponent}) else {
            return []
        }
        
        let decoder = JSONDecoder()
        
        do {
            var stories = try contents.compactMap { url -> HPACKStory? in
                // for some reason using filter({ $0.pathExtension == "json" }) throws the compiler type-checker for a loop
                guard url.pathExtension == "json" else { return nil }
                let data = try Data(contentsOf: url, options: [.uncached, .mappedIfSafe])
                return try decoder.decode(HPACKStory.self, from: data)
            }
            
            // ensure there are valid non-zero sequence numbers
            // to ensure we modify these value types in-place we apparently need to use collection subscripting for all accesses
            // it seems that if there are sequence numbers on any cases they're on all cases; we can optimize for that.
            for idx in stories.indices where stories[idx].cases.count > 1 && stories[idx].cases[1].seqno == 0 {
                for cidx in stories[idx].cases.indices {
                    stories[idx].cases[cidx].seqno = cidx
                }
            }
            return stories
        } catch {
            XCTFail("Failed to decode encoder stories from JSON files")
            return []
        }
    }
    
    private func runEncodingTests(withOutput type: TestType) {
        let huffmanEncoded = type == .swiftNIOHuffman
        let stories = loadStories(for: .encoding)
        guard stories.count > 0 else {
            // we don't have the data, so don't go failing any tests
            return
        }
        
        let outputDir = getSourceURL(for: type)
        if FileManager.default.fileExists(atPath: outputDir.path) == false {
            try! FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        var outputs: [HPACKStory] = []
        
        let start = Date()
        
        for (idx, story) in stories.enumerated() {
            let encoded = runEncodeStory(story, idx, huffmanEncoded: huffmanEncoded)
            outputs.append(encoded)
        }
        
        let end = Date()
        print("Encoding took \(String(format: "%.02f", end.timeIntervalSince(start))) seconds.")
        
        for (idx, story) in outputs.enumerated() {
            writeOutputStory(story, at: idx, to: outputDir)
        }
    }
    
    // funky names to ensure the encoder tests run before the decoder tests.
    func testAAEncoderWithoutHuffmanCoding() {
        runEncodingTests(withOutput: .swiftNIOPlain)
    }
    
    // funky names to ensure the encoder tests run before the decoder tests.
    func testABEncoderWithHuffmanCoding() {
        runEncodingTests(withOutput: .swiftNIOHuffman)
    }
    
    func testDecoder() {
        var testTimings: [TestType : TimeInterval] = [:]
        
        for test in TestType.allCases where test != .encoding {
            let duration = _testDecoder(for: test)
            testTimings[test] = duration
        }
        
        print("Test timing metrics:")
        for (test, duration) in testTimings {
            let testName = test.rawValue
            var firstPart = " - \(testName) "
            if firstPart.count < 40 {
                firstPart.append(String(repeating: " ", count: 40 - firstPart.count))
            }
            
            print("\(firstPart) : \(String(format: "%.02f", duration)) seconds.")
        }
    }
    
    private func _testDecoder(for test: TestType) -> TimeInterval {
        let loadStart = Date()
        print("Loading \(test.rawValue)...", terminator: "")
        let stories = loadStories(for: test)
        let loadTime = Date().timeIntervalSince(loadStart)
        guard stories.count > 0 else {
            // no input data = no problems
            print(" no stories found.")
            return 0
        }
        print(" done. Load time = \(String(format: "%.02f", loadTime)) seconds.")
        
        // description comes from first test case
        if let description = stories.first!.description {
            print(description)
        }
        
        let start = Date()
        
        for (idx, story) in stories.enumerated() {
            var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
            
            for testCase in story.cases {
                do {
                    if let size = testCase.headerTableSize {
                        decoder.maxDynamicTableLength = size
                    }
                    
                    guard var bytes = testCase.wire else {
                        XCTFail("Decoder story case \(testCase.seqno) has no wire data to decode!")
                        return Date().timeIntervalSince(start)
                    }
                    let decoded = try decoder.decodeHeaders(from: &bytes)
                    XCTAssertEqual(testCase.headers, decoded)
                } catch {
                    print("  \(testCase.seqno) - failed.")
                    XCTFail("Failure in story \(idx), case \(testCase.seqno) - \(error)")
                }
            }
        }
        
        return Date().timeIntervalSince(start)
    }
    
    private func writeOutputStory(_ story: HPACKStory, at index: Int, to directory: URL) {
        let outURL = directory
            .appendingPathComponent(String(format: "story_%02d", index), isDirectory: false)
            .appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        do {
            let data = try encoder.encode(story)
            try data.write(to: outURL, options: [.atomic])
        } catch {
            print("Error writing encoded test case: \(error)")
        }
    }
    
    private func runEncodeStory(_ story: HPACKStory, _ index: Int, huffmanEncoded: Bool = true) -> HPACKStory {
        // do we need to care about the context?
        var encoder = HPACKEncoder(allocator: ByteBufferAllocator(), useHuffmanEncoding: huffmanEncoded)
        var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
        
        var result = story
        result.cases.removeAll()
        if huffmanEncoded {
            result.description = "Encoded using the HPACK implementation of swift-nio-http2, with static table, dynamic table, and huffman encoded strings: <https://github.com/apple/swift-nio-http2>"
        } else {
            result.description = "Encoded using the HPACK implementation of swift-nio-http2, with static table, dynamic table, and plain-text encoded strings: <https://github.com/apple/swift-nio-http2>"
        }
        
        for storyCase in story.cases {
            do {
                if let tableSize = storyCase.headerTableSize {
                    try encoder.setDynamicTableSize(tableSize)
                    decoder.maxDynamicTableLength = tableSize
                }
                
                try encoder.beginEncoding(allocator: ByteBufferAllocator())
                try encoder.append(headers: storyCase.headers)
                
                var outputCase = storyCase
                var encoded = try encoder.endEncoding()
                outputCase.wire = encoded
                result.cases.append(outputCase)
                
                // now try to decode it
                let decoded = try decoder.decodeHeaders(from: &encoded)
                XCTAssertEqual(storyCase.headers, decoded)
            } catch {
                print("  \(storyCase.seqno) - failed.")
                XCTFail("Failure in story \(index), case \(storyCase.seqno) - \(error)")
            }
        }
        
        // the output story now has all the wire values filled in
        return result
    }
    
}

struct HPACKStory : Codable {
    var context: HPACKStoryContext?
    var description: String?
    var cases: [HPACKStoryCase]
}

enum HPACKStoryContext : String, Codable {
    case request
    case response
}

struct HPACKStoryCase : Codable {
    var seqno: Int
    var headerTableSize: Int?
    var wire: ByteBuffer?
    var headers: HPACKHeaders
    
    private enum Keys : String, CodingKey {
        case seqno
        case headerTableSize = "header_table_size"
        case wire
        case headers
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.seqno = try container.decodeIfPresent(Int.self, forKey: .seqno) ?? 0
        self.headerTableSize = try container.decodeIfPresent(Int.self, forKey: .headerTableSize)
        
        if let wireString = try container.decodeIfPresent(String.self, forKey: .wire) {
            self.wire = decodeHexData(from: wireString)
        } else {
            self.wire = nil
        }
        
        let rawHeaders = try container.decode([[String : String]].self, forKey: .headers)
        let pairs = rawHeaders.map { ($0.first!.key, $0.first!.value) }
        self.headers = HPACKHeaders(pairs)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(self.seqno, forKey: .seqno)
        try container.encode(self.headerTableSize, forKey: .headerTableSize)
        
        if let bytes = self.wire {
            try container.encode(encodeHex(data: bytes), forKey: .wire)
        }
        
        let rawHeaders = self.headers.map { [$0.0 : $0.1] }
        try container.encode(rawHeaders, forKey: .headers)
    }
}

fileprivate func decodeHexData(from string: String) -> ByteBuffer {
    var bytes: [UInt8] = []
    var idx = string.startIndex
    
    repeat {
        let byteStr = string[idx...string.index(after: idx)]
        bytes.append(UInt8(byteStr, radix: 16)!)
        idx = string.index(idx, offsetBy: 2)
        
    } while string.distance(from: idx, to: string.endIndex) > 1
    
    var buf = ByteBufferAllocator().buffer(capacity: bytes.count)
    _ = buf.writeBytes(bytes)
    return buf
}

fileprivate func encodeHex(data: ByteBuffer) -> String {
    var result = ""
    for byte in data.readableBytesView {
        let str = String(byte, radix: 16)
        if str.count == 1 {
            result.append("0")
        }
        result.append(str)
    }
    return result
}
