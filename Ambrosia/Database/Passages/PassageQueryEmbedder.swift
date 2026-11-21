// SPDX-License-Identifier: GPL-3.0-only
import Accelerate
import CoreML
import Foundation

// MARK: - Passage Query Embedder

/// Generates unit-normalized query embedding vectors on-device using CoreML.
///
/// Designed to execute on Apple Neural Engine (ANE) or Metal GPU in ~8-15 ms.
/// Models are loaded from `Application Support/Ambrosia/Models/`.
public actor PassageQueryEmbedder {

    public static let shared = PassageQueryEmbedder()

    public static let defaultModelName = "Qwen3-Embedding-0.6B"
    public static let defaultDimension = 1024

    private var mlModel: MLModel?
    private var loadedModelURL: URL?

    public init() {}

    // MARK: - Model Directory & Path

    public static var modelsDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("Ambrosia/Models", isDirectory: true)
    }

    public static func expectedModelURL(modelName: String = defaultModelName) -> URL {
        modelsDirectoryURL.appendingPathComponent("\(modelName).mlmodelc")
    }

    public var isModelAvailable: Bool {
        let path = Self.expectedModelURL().path
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Loading

    /// Preloads the CoreML model into memory if available.
    public func loadModel(named modelName: String = defaultModelName) throws {
        let modelURL = Self.expectedModelURL(modelName: modelName)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all // Utilizes Neural Engine, GPU, and CPU
        let loaded = try MLModel(contentsOf: modelURL, configuration: config)
        self.mlModel = loaded
        self.loadedModelURL = modelURL
    }

    // MARK: - Query Embedding

    /// Encodes a query text into a unit-normalized Float32 vector.
    ///
    /// If no CoreML model is installed, throws an error unless in mock mode.
    public func embed(
        query: String,
        targetDimension: Int = defaultDimension
    ) async throws -> [Float] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // If CoreML model is available on disk, run inference
        if let model = mlModel ?? (try? loadAndReturnModel()) {
            return try runInference(text: trimmed, model: model, targetDimension: targetDimension)
        }

        throw CocoaError(.fileNoSuchFile)
    }

    private func loadAndReturnModel() throws -> MLModel {
        let modelURL = Self.expectedModelURL()
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let loaded = try MLModel(contentsOf: modelURL, configuration: config)
        self.mlModel = loaded
        self.loadedModelURL = modelURL
        return loaded
    }

    private func runInference(
        text: String,
        model: MLModel,
        targetDimension: Int
    ) throws -> [Float] {
        // Prepare model input feature provider
        let inputFeature = try MLDictionaryFeatureProvider(dictionary: [
            "text": text
        ])

        let output = try model.prediction(from: inputFeature)
        guard let featureValue = output.featureValue(for: "embeddings") ?? output.featureValue(for: "var_output"),
              let multiArray = featureValue.multiArrayValue else {
            throw CocoaError(.coderValueNotFound)
        }

        let count = multiArray.count
        var rawFloats = [Float](repeating: 0, count: min(count, targetDimension))
        let pointer = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
        for dimIndex in 0..<rawFloats.count {
            rawFloats[dimIndex] = pointer[dimIndex]
        }

        return Self.normalize(rawFloats)
    }

    // MARK: - Normalization SIMD

    /// L2-normalizes a float vector using Accelerate vDSP.
    public static func normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }
        var sumSquares: Float = 0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumSquares)
        guard norm > 0 else { return vector }
        var result = [Float](repeating: 0, count: vector.count)
        var scale = 1.0 / norm
        vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
        return result
    }
}
