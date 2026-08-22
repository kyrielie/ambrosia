import XCTest
import Compression
@testable import Ambrosia

// Covers GzipEncoder.gzip(_:), the hand-rolled RFC 1952 gzip framing used
// for LocalFeedServer's Content-Encoding: gzip bodies (see GzipEncoder.swift's
// header comment for why this isn't NSData.compressed(using: .zlib)).
//
// The round-trip test decodes the deflate payload with
// compression_decode_buffer -- the decode counterpart to the
// compression_encode_buffer call GzipEncoder.rawDeflate already makes, same
// buffer-API shape, confirmed against Apple's Compression framework docs.
// This does not use `gunzip`/Foundation gzip decoding anywhere, since the
// whole point of this encoder is that Foundation's own zlib-framed API is
// NOT gzip-compatible -- see the source file's comment.
final class GzipEncoderTests: XCTestCase {

    // MARK: - Structural framing (RFC 1952 header/trailer, independent of payload)

    func test_output_startsWithGzipMagicBytesAndDeflateMethod() throws {
        let output = try GzipEncoder.gzip(Data("hello".utf8))
        XCTAssertGreaterThanOrEqual(output.count, 18) // 10-byte header + 8-byte trailer minimum
        let header = Array(output.prefix(10))
        XCTAssertEqual(header[0], 0x1f)
        XCTAssertEqual(header[1], 0x8b)
        XCTAssertEqual(header[2], 0x08) // CM = deflate
        XCTAssertEqual(header[3], 0x00) // FLG = 0, no optional fields
    }

    func test_trailer_encodesOriginalSizeLittleEndian() throws {
        let payload = Data(repeating: 0x41, count: 300) // 300 = 0x012C
        let output = try GzipEncoder.gzip(payload)
        let isizeBytes = output.suffix(4)
        let isize = isizeBytes.enumerated().reduce(UInt32(0)) { acc, pair in
            acc | (UInt32(pair.element) << (8 * pair.offset))
        }
        XCTAssertEqual(isize, UInt32(payload.count))
    }

    // MARK: - Round trip via Compression's raw-deflate decoder

    func test_roundTrip_emptyData() throws {
        // Edge case worth flagging: rawDeflate's `guard writtenCount > 0`
        // (GzipEncoder.swift) throws .deflateFailed if compression_encode_buffer
        // returns 0 bytes written for empty input. If this test fails with
        // .deflateFailed rather than an assertion mismatch, that guard needs
        // a `data.isEmpty` special case rather than the round-trip logic
        // being wrong -- this test's job is to surface which one it is.
        try assertRoundTrips(Data())
    }

    func test_roundTrip_shortAsciiPayload() throws {
        try assertRoundTrips(Data("The quick brown fox jumps over the lazy dog".utf8))
    }

    func test_roundTrip_repetitiveLargePayload() throws {
        // Large + repetitive: exercises the compressible path, not just the
        // near-incompressible small-input path the tests above cover.
        let payload = Data(String(repeating: "gzip round trip ", count: 5000).utf8)
        try assertRoundTrips(payload)
    }

    func test_roundTrip_incompressibleRandomPayload() throws {
        // Confirms the `dstCapacity = data.count + 512` headroom in
        // rawDeflate is sufficient even when deflate can't shrink the input.
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try assertRoundTrips(payload)
    }

    // MARK: - Helper

    /// gzip-encodes `original`, strips the RFC 1952 header/trailer, and
    /// decodes the remaining raw-deflate body back with
    /// compression_decode_buffer, mirroring GzipEncoder.rawDeflate's own use
    /// of compression_encode_buffer with COMPRESSION_ZLIB (Apple's naming for
    /// raw/headerless deflate, not zlib framing).
    private func assertRoundTrips(_ original: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let gzipped = try GzipEncoder.gzip(original)
        XCTAssertGreaterThanOrEqual(gzipped.count, 18, file: file, line: line)

        let deflateBody = gzipped.dropFirst(10).dropLast(8)
        let decoded = try decompress(Data(deflateBody), expectedSize: original.count)
        XCTAssertEqual(decoded, original, file: file, line: line)
    }

    private func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        // expectedSize can be 0 (empty input); give decode_buffer a
        // minimum-sized destination so it always has somewhere to write.
        let dstCapacity = max(expectedSize, 1)
        var dst = [UInt8](repeating: 0, count: dstCapacity)

        let writtenCount: Int = data.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Int in
            guard let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBufferPointer { dstPtr -> Int in
                guard let dstBase = dstPtr.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstBase, dstCapacity,
                    srcBase, data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard expectedSize == 0 || writtenCount > 0 else {
            throw NSError(domain: "GzipEncoderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "decode failed"])
        }
        return Data(dst[0..<writtenCount])
    }
}
