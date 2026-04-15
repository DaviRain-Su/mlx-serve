import XCTest
import Foundation

// =============================================================================
// MARK: - Type replicas for testing (matches HFModels.swift)
// =============================================================================

private struct TestHFSafetensors: Codable {
    let parameters: [String: Int64]?
    let total: Int64?
}

private let testCompatiblePipelineTags: Set<String> = [
    "text-generation", "image-text-to-text", "any-to-any",
]

private struct TestHFModel: Identifiable, Codable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let tags: [String]?
    let safetensors: TestHFSafetensors?
    let pipelineTag: String?

    enum CodingKeys: String, CodingKey {
        case id, downloads, likes, lastModified, tags, safetensors
        case pipelineTag = "pipeline_tag"
    }

    var isCompatible: Bool {
        guard let tag = pipelineTag, !tag.isEmpty else { return true }
        return testCompatiblePipelineTags.contains(tag)
    }

    var hasVision: Bool {
        let tag = pipelineTag ?? ""
        return tag == "image-text-to-text" || tag == "any-to-any"
    }

    var hasToolCalling: Bool {
        let lower = id.lowercased()
        let isInstructTuned = lower.contains("-it") || lower.contains("-instruct") || lower.contains("-chat")
        guard isInstructTuned else { return false }
        let toolFamilies = ["gemma-4", "gemma-3", "qwen3", "qwen2.5", "llama-3", "mistral"]
        return toolFamilies.contains { lower.contains($0) }
    }

    var author: String {
        id.split(separator: "/").first.map(String.init) ?? ""
    }
    var modelName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
    var quantization: String? {
        let lower = id.lowercased()
        if lower.contains("4bit") || lower.contains("4-bit") || lower.contains("q4_") { return "4-bit" }
        if lower.contains("3bit") || lower.contains("3-bit") { return "3-bit" }
        if lower.contains("6bit") || lower.contains("6-bit") { return "6-bit" }
        if lower.contains("8bit") || lower.contains("8-bit") || lower.contains("q8_") { return "8-bit" }
        if lower.contains("fp16") { return "FP16" }
        if lower.contains("bf16") { return "BF16" }
        return nil
    }
    var estimatedSizeBytes: Int64 {
        guard let params = safetensors?.parameters else { return 0 }
        var total: Int64 = 0
        for (dtype, count) in params {
            let bytesPerParam: Double
            switch dtype.uppercased() {
            case "F64": bytesPerParam = 8
            case "F32", "U32", "I32": bytesPerParam = 4
            case "F16", "BF16", "U16", "I16": bytesPerParam = 2
            case "I8", "U8": bytesPerParam = 1
            case let d where d.contains("4"): bytesPerParam = 0.5
            default: bytesPerParam = 2
            }
            total += Int64(Double(count) * bytesPerParam)
        }
        return total
    }
    var modelSize: String {
        let name = modelName
        let pattern = #"(?:^|[-_])[Ee]?(\d+(?:\.\d+)?[BbMm])(?![Ii])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else {
            return "\u{2014}"
        }
        return String(name[range]).uppercased()
    }
    var lastModifiedDate: Date? {
        guard let lastModified else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: lastModified) ?? ISO8601DateFormatter().date(from: lastModified)
    }
}

// =============================================================================
// MARK: - Unit tests
// =============================================================================

final class HFModelTests: XCTestCase {

    func testQuantizationParsing() {
        XCTAssertEqual(TestHFModel.make(id: "x/model-4bit").quantization, "4-bit")
        XCTAssertEqual(TestHFModel.make(id: "x/model-8bit").quantization, "8-bit")
        XCTAssertEqual(TestHFModel.make(id: "x/model-bf16").quantization, "BF16")
        XCTAssertEqual(TestHFModel.make(id: "x/model-fp16").quantization, "FP16")
        XCTAssertEqual(TestHFModel.make(id: "x/model-3bit").quantization, "3-bit")
        XCTAssertNil(TestHFModel.make(id: "x/plain-model").quantization)
    }

    func testAuthorAndModelName() {
        let m = TestHFModel.make(id: "mlx-community/gemma-4-e2b-it-4bit")
        XCTAssertEqual(m.author, "mlx-community")
        XCTAssertEqual(m.modelName, "gemma-4-e2b-it-4bit")
    }

    func testSizeEstimation_BF16AndU32() {
        let m = TestHFModel.make(
            id: "test/model",
            safetensors: TestHFSafetensors(
                parameters: ["BF16": 631_148_099, "U32": 579_616_768],
                total: 1_210_764_867
            )
        )
        // BF16: 631M * 2 = 1.26 GB, U32: 579M * 4 = 2.32 GB → ~3.58 GB
        let sizeGB = Double(m.estimatedSizeBytes) / (1024 * 1024 * 1024)
        XCTAssertGreaterThan(sizeGB, 3.0)
        XCTAssertLessThan(sizeGB, 4.0)
    }

    func testSizeEstimation_NoSafetensors() {
        let m = TestHFModel.make(id: "test/model")
        XCTAssertEqual(m.estimatedSizeBytes, 0)
    }

    func testDateParsing() {
        let m = TestHFModel.make(id: "x/m", lastModified: "2026-04-13T13:07:28.000Z")
        XCTAssertNotNil(m.lastModifiedDate)
        let m2 = TestHFModel.make(id: "x/m")
        XCTAssertNil(m2.lastModifiedDate)
    }

    func testDecodeRealAPIShape() throws {
        let json = """
        [
            {
                "_id": "69cea456",
                "id": "mlx-community/gemma-4-e2b-it-4bit",
                "lastModified": "2026-04-13T13:07:28.000Z",
                "downloads": 132195,
                "likes": 7,
                "tags": ["mlx", "safetensors"],
                "safetensors": {
                    "parameters": {"BF16": 631148099, "U32": 579616768},
                    "total": 1210764867
                }
            },
            {
                "_id": "abc",
                "id": "mlx-community/minimal-model"
            }
        ]
        """
        let models = try JSONDecoder().decode([TestHFModel].self, from: json.data(using: .utf8)!)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].downloads, 132195)
        XCTAssertEqual(models[0].quantization, "4-bit")
        XCTAssertGreaterThan(models[0].estimatedSizeBytes, 0)
        XCTAssertNil(models[1].downloads)
        XCTAssertEqual(models[1].estimatedSizeBytes, 0)
    }

    func testClientSideSort_Downloads() {
        let models = [
            TestHFModel.make(id: "x/a", downloads: 100),
            TestHFModel.make(id: "x/b", downloads: 500),
            TestHFModel.make(id: "x/c", downloads: 50),
        ]
        let descending = models.sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }
        XCTAssertEqual(descending.map(\.id), ["x/b", "x/a", "x/c"])
        let ascending = models.sorted { ($0.downloads ?? 0) < ($1.downloads ?? 0) }
        XCTAssertEqual(ascending.map(\.id), ["x/c", "x/a", "x/b"])
    }

    func testCompatibility_TextGeneration() {
        XCTAssertTrue(TestHFModel.make(id: "x/m", pipelineTag: "text-generation").isCompatible)
        XCTAssertTrue(TestHFModel.make(id: "x/m", pipelineTag: "image-text-to-text").isCompatible)
        XCTAssertTrue(TestHFModel.make(id: "x/m", pipelineTag: "any-to-any").isCompatible)
    }

    func testCompatibility_NilPipelineIsCompatible() {
        XCTAssertTrue(TestHFModel.make(id: "x/m").isCompatible)
        XCTAssertTrue(TestHFModel.make(id: "x/m", pipelineTag: "").isCompatible)
    }

    func testVisionCapability() {
        XCTAssertTrue(TestHFModel.make(id: "x/m", pipelineTag: "image-text-to-text").hasVision)
        XCTAssertTrue(TestHFModel.make(id: "x/m", pipelineTag: "any-to-any").hasVision)
        XCTAssertFalse(TestHFModel.make(id: "x/m", pipelineTag: "text-generation").hasVision)
        XCTAssertFalse(TestHFModel.make(id: "x/m").hasVision)
    }

    func testToolCallingCapability() {
        // Instruction-tuned from known families → has tool calling
        XCTAssertTrue(TestHFModel.make(id: "mlx-community/gemma-4-e2b-it-4bit").hasToolCalling)
        XCTAssertTrue(TestHFModel.make(id: "mlx-community/qwen3-8b-instruct").hasToolCalling)
        XCTAssertTrue(TestHFModel.make(id: "mlx-community/llama-3-8b-instruct").hasToolCalling)
        // Not instruction-tuned → no tool calling
        XCTAssertFalse(TestHFModel.make(id: "mlx-community/gemma-4-e2b-4bit").hasToolCalling)
        // Unknown family → no tool calling
        XCTAssertFalse(TestHFModel.make(id: "mlx-community/custom-model-it").hasToolCalling)
    }

    func testCompatibility_UnsupportedPipelines() {
        XCTAssertFalse(TestHFModel.make(id: "x/m", pipelineTag: "text-to-speech").isCompatible)
        XCTAssertFalse(TestHFModel.make(id: "x/m", pipelineTag: "automatic-speech-recognition").isCompatible)
        XCTAssertFalse(TestHFModel.make(id: "x/m", pipelineTag: "image-classification").isCompatible)
    }

    func testClientSideSort_EstimatedSize() {
        let small = TestHFModel.make(id: "x/small", safetensors: TestHFSafetensors(parameters: ["BF16": 1_000_000], total: 1_000_000))
        let large = TestHFModel.make(id: "x/large", safetensors: TestHFSafetensors(parameters: ["BF16": 1_000_000_000], total: 1_000_000_000))
        let none = TestHFModel.make(id: "x/none")
        let sorted = [small, large, none].sorted { $0.estimatedSizeBytes > $1.estimatedSizeBytes }
        XCTAssertEqual(sorted.map(\.id), ["x/large", "x/small", "x/none"])
    }

    // MARK: - Model size parsing from name

    func testModelSize_CommonPatterns() {
        XCTAssertEqual(TestHFModel.make(id: "x/gemma-4-31b-it-4bit").modelSize, "31B")
        XCTAssertEqual(TestHFModel.make(id: "x/gemma-4-e2b-it-4bit").modelSize, "2B")
        XCTAssertEqual(TestHFModel.make(id: "x/gemma-4-e4b-it-4bit").modelSize, "4B")
        XCTAssertEqual(TestHFModel.make(id: "x/gemma-4-26b-a4b-it-4bit").modelSize, "26B")
        XCTAssertEqual(TestHFModel.make(id: "x/Kokoro-82M-bf16").modelSize, "82M")
        XCTAssertEqual(TestHFModel.make(id: "x/parakeet-tdt-0.6b-v2").modelSize, "0.6B")
        XCTAssertEqual(TestHFModel.make(id: "x/LFM2-24B-A2B-MLX-4bit").modelSize, "24B")
        XCTAssertEqual(TestHFModel.make(id: "x/DeepSeek-R1-0528-Qwen3-8B-MLX-4bit").modelSize, "8B")
        XCTAssertEqual(TestHFModel.make(id: "x/LFM2.5-1.2B-Instruct-MLX-8bit").modelSize, "1.2B")
    }

    func testModelSize_DoesNotMatchQuantBits() {
        // "8bit" should NOT be parsed as "8B"
        XCTAssertEqual(TestHFModel.make(id: "x/Qwen3-Coder-Next-8bit").modelSize, "\u{2014}")
        XCTAssertEqual(TestHFModel.make(id: "x/GLM-4.7-Flash-MLX-8bit").modelSize, "\u{2014}")
    }

    func testModelSize_NoMatch() {
        XCTAssertEqual(TestHFModel.make(id: "x/Kimi-K2.5").modelSize, "\u{2014}")
    }
}

// =============================================================================
// MARK: - Integration tests (hits real HuggingFace API)
// =============================================================================

final class HFSearchIntegrationTests: XCTestCase {

    private func buildURL(search: String? = nil, limit: Int = 5) -> URL {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "filter", value: "mlx"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if let search {
            items.append(URLQueryItem(name: "search", value: search))
        }
        for field in ["safetensors", "lastModified", "likes", "downloads", "tags"] {
            items.append(URLQueryItem(name: "expand[]", value: field))
        }
        components.queryItems = items
        return components.url!
    }

    func testFetchMLXModels_ReturnsResults() async throws {
        let url = buildURL()
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 200)

        let models = try JSONDecoder().decode([TestHFModel].self, from: data)
        XCTAssertGreaterThanOrEqual(models.count, 1, "Should find at least 1 MLX model")
        XCTAssertFalse(models[0].id.isEmpty)
        XCTAssertNotNil(models[0].downloads, "expand[]=downloads should populate field")
    }

    func testSearchGemma_ReturnsGemmaModels() async throws {
        let url = buildURL(search: "gemma")
        let (data, _) = try await URLSession.shared.data(from: url)
        let models = try JSONDecoder().decode([TestHFModel].self, from: data)
        XCTAssertGreaterThanOrEqual(models.count, 1, "Searching 'gemma' should find MLX models")
        for m in models {
            XCTAssertTrue(m.id.lowercased().contains("gemma"), "\(m.id) should contain 'gemma'")
        }
    }

    func testSafetensorsExpand_PopulatesSizeData() async throws {
        let url = buildURL(search: "gemma-4-e2b-it-4bit", limit: 10)
        let (data, _) = try await URLSession.shared.data(from: url)
        let models = try JSONDecoder().decode([TestHFModel].self, from: data)

        if let target = models.first(where: { $0.id == "mlx-community/gemma-4-e2b-it-4bit" }) {
            XCTAssertNotNil(target.safetensors, "Known model should have safetensors metadata")
            let sizeGB = Double(target.estimatedSizeBytes) / (1024 * 1024 * 1024)
            XCTAssertGreaterThan(sizeGB, 2.0, "gemma-4-e2b-it-4bit should be > 2 GB")
            XCTAssertLessThan(sizeGB, 5.0, "gemma-4-e2b-it-4bit should be < 5 GB")
        }
    }

    func testPagination_SkipWorks() async throws {
        // Fetch page 1
        let url1 = buildURL(limit: 3)
        let (data1, _) = try await URLSession.shared.data(from: url1)
        let page1 = try JSONDecoder().decode([TestHFModel].self, from: data1)

        // Fetch page 2 with skip=3
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "mlx"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "skip", value: "3"),
            URLQueryItem(name: "expand[]", value: "downloads"),
        ]
        let (data2, _) = try await URLSession.shared.data(from: components.url!)
        let page2 = try JSONDecoder().decode([TestHFModel].self, from: data2)

        XCTAssertGreaterThanOrEqual(page1.count, 1)
        XCTAssertGreaterThanOrEqual(page2.count, 1)
        // Pages should not overlap
        let page1Ids = Set(page1.map(\.id))
        let page2Ids = Set(page2.map(\.id))
        XCTAssertTrue(page1Ids.isDisjoint(with: page2Ids), "Page 1 and 2 should have different models")
    }
}

// MARK: - Test helper

private extension TestHFModel {
    static func make(
        id: String,
        downloads: Int? = nil,
        likes: Int? = nil,
        lastModified: String? = nil,
        safetensors: TestHFSafetensors? = nil,
        pipelineTag: String? = nil
    ) -> TestHFModel {
        TestHFModel(id: id, downloads: downloads, likes: likes, lastModified: lastModified, tags: nil, safetensors: safetensors, pipelineTag: pipelineTag)
    }
}
