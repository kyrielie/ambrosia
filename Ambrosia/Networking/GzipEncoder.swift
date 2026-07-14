import Foundation
import Compression

// MARK: - GzipEncoder
//
// A minimal RFC 1952 gzip encoder for HTTP `Content-Encoding: gzip` bodies.
//
// Deliberately not `NSData.compressed(using: .zlib)`: that Foundation-native
// API produces a *zlib*-framed stream (RFC 1950 — 2-byte header, Adler-32
// trailer), not a *gzip*-framed one (RFC 1952 — 10-byte header with magic
// bytes 0x1f 0x8b, CRC-32 + little-endian ISIZE trailer). `URLSession`'s
// transparent `Content-Encoding: gzip` decoding expects the latter; feeding
// it zlib framing under a `gzip` label does not round-trip. See
// docs/ambrosia-feed-transfer-phase0-findings.md for how this was found.
//
// This wraps Apple's `Compression` framework's raw-deflate output
// (`COMPRESSION_ZLIB` is Apple's naming for the raw zlib/deflate algorithm,
// not zlib *framing* — the framework emits headerless deflate here, which is
// exactly the payload a gzip envelope wants) in a hand-built gzip header and
// trailer. No third-party dependency.
enum GzipEncoder {

    enum GzipError: Error {
        case deflateFailed
    }

    /// Compresses `data` into a complete RFC 1952 gzip byte stream.
    static func gzip(_ data: Data) throws -> Data {
        let deflated = try rawDeflate(data)

        var output = Data()
        // 10-byte gzip header: magic (1f 8b), CM=8 (deflate), FLG=0,
        // MTIME=0 (not meaningful for HTTP bodies), XFL=0, OS=255 (unknown).
        output.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        output.append(deflated)

        let crc = crc32(data)
        output.append(uint32LE(crc))
        output.append(uint32LE(UInt32(truncatingIfNeeded: data.count)))
        return output
    }

    // MARK: - Raw deflate via Compression framework

    private static func rawDeflate(_ data: Data) throws -> Data {
        // Destination buffer: deflate can theoretically expand incompressible
        // input slightly; +512 headroom covers that for any realistic feed
        // payload size without a resize/retry loop.
        let dstCapacity = data.count + 512
        var dst = [UInt8](repeating: 0, count: dstCapacity)

        let writtenCount: Int = data.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Int in
            guard let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBufferPointer { dstPtr -> Int in
                guard let dstBase = dstPtr.baseAddress else { return 0 }
                return compression_encode_buffer(
                    dstBase, dstCapacity,
                    srcBase, data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard writtenCount > 0 else { throw GzipError.deflateFailed }
        return Data(dst[0..<writtenCount])
    }

    // MARK: - CRC-32 (standard gzip polynomial 0xEDB88320)

    private static let crcTable: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }
}
