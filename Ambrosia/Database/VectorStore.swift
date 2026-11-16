// SPDX-License-Identifier: GPL-3.0-only
import Accelerate
import Foundation

/// Row-major, L2-normalized embedding vectors.
public struct EmbeddingMatrix: Sendable, Equatable {
    public let rows: Int
    public let dimension: Int
    public let values: [Float]

    public init(rows: Int, dimension: Int, values: [Float]) {
        self.rows = rows
        self.dimension = dimension
        self.values = values
    }
}

/// Binary vector store using Apple Silicon SIMD mapping and Accelerate BLAS matrix math.
public enum VectorStore {
    private static let magic: UInt32 = 0x4C46_5631 // "LFV1"

    public static func read(from url: URL) -> EmbeddingMatrix? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 12 else { return nil }
        return data.withUnsafeBytes { raw -> EmbeddingMatrix? in
            let fileMagic = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let rows = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let dimension = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            guard fileMagic == magic, data.count == 12 + rows * dimension * MemoryLayout<Float>.size else { return nil }
            let values = [Float](unsafeUninitializedCapacity: rows * dimension) { buffer, count in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[12...]))
                count = rows * dimension
            }
            return EmbeddingMatrix(rows: rows, dimension: dimension, values: values)
        }
    }

    public static func write(_ matrix: EmbeddingMatrix, to url: URL) throws {
        guard matrix.values.count == matrix.rows * matrix.dimension else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var data = Data()
        data.reserveCapacity(12 + matrix.values.count * MemoryLayout<Float>.size)
        for value in [magic, UInt32(matrix.rows), UInt32(matrix.dimension)] {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        matrix.values.withUnsafeBytes { data.append(contentsOf: $0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Evaluates cosine similarities for all rows in matrix against a unit-normalized query vector
    /// using Apple Accelerate BLAS `cblas_sgemv`.
    public static func cosineSimilarities(matrix: EmbeddingMatrix, query: [Float]) -> [Float] {
        guard matrix.rows > 0, matrix.dimension == query.count else { return [] }
        var scores = [Float](repeating: 0, count: matrix.rows)
        cblas_sgemv(
            CblasRowMajor, CblasNoTrans,
            Int32(matrix.rows), Int32(matrix.dimension),
            1.0, matrix.values, Int32(matrix.dimension),
            query, 1,
            0.0, &scores, 1
        )
        return scores
    }
}
