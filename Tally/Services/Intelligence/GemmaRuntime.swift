import Foundation

enum GemmaRuntimeError: LocalizedError {
    case frameworkUnavailable
    case modelLoadFailed
    case contextCreationFailed
    case samplerCreationFailed
    case promptFormattingFailed
    case tokenizationFailed
    case promptExceedsContextWindow(tokenCount: Int, maxSupported: Int)
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            return "The local Gemma runtime framework is unavailable in this build."
        case .modelLoadFailed:
            return "The Gemma model could not be loaded."
        case .contextCreationFailed:
            return "The Gemma inference context could not be created."
        case .samplerCreationFailed:
            return "The Gemma sampler could not be created."
        case .promptFormattingFailed:
            return "The Gemma prompt could not be formatted."
        case .tokenizationFailed:
            return "The Gemma prompt could not be tokenized."
        case let .promptExceedsContextWindow(tokenCount, maxSupported):
            return "The Gemma prompt was too large (\(tokenCount) tokens; max supported is \(maxSupported))."
        case let .decodeFailed(status):
            return "Gemma decoding failed with status \(status)."
        }
    }
}

#if canImport(llama) && os(macOS)
import llama

private enum GemmaRuntimeLimits {
    static let contextWindow: UInt32 = 4096
    static let batchSize: UInt32 = 1024
    static let microBatchSize: UInt32 = 512
}

actor GemmaRuntime {
    static let shared = GemmaRuntime()
    static let isAvailable = true

    private var didInitializeBackend = false
    private var loadedModelURL: URL?
    private var loadedModel: OpaquePointer?

    func generateText(
        modelURL: URL,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int = 512,
        temperature: Float = 0
    ) throws -> String {
        let model = try ensureLoadedModel(at: modelURL)
        guard let vocab = llama_model_get_vocab(model) else {
            throw GemmaRuntimeError.modelLoadFailed
        }

        let context = try makeContext(for: model)
        defer { llama_free(context) }

        let prompt = try formatPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt)
        let promptTokens = try tokenize(prompt, vocab: vocab)
        try validatePromptBudget(promptTokenCount: promptTokens.count, maxTokens: maxTokens)
        try decode(promptTokens, in: context)

        let sampler = try makeSampler(temperature: temperature)
        defer { llama_sampler_free(sampler) }

        var generatedTokens: [llama_token] = []
        generatedTokens.reserveCapacity(maxTokens)

        for _ in 0..<maxTokens {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                break
            }

            generatedTokens.append(token)
            llama_sampler_accept(sampler, token)
            try decode([token], in: context)
        }

        return detokenize(generatedTokens, vocab: vocab)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unloadModelForTesting() {
        if let loadedModel {
            llama_model_free(loadedModel)
            self.loadedModel = nil
            loadedModelURL = nil
        }

        if didInitializeBackend {
            llama_backend_free()
            didInitializeBackend = false
        }
    }

    private func ensureLoadedModel(at modelURL: URL) throws -> OpaquePointer {
        if let loadedModel, loadedModelURL == modelURL {
            return loadedModel
        }

        if didInitializeBackend == false {
            llama_backend_init()
            didInitializeBackend = true
        }

        if let loadedModel {
            llama_model_free(loadedModel)
            self.loadedModel = nil
            loadedModelURL = nil
        }

        var params = llama_model_default_params()
        params.n_gpu_layers = -1
        params.use_mmap = true

        let model = modelURL.path.withCString { pathPointer in
            llama_model_load_from_file(pathPointer, params)
        }

        guard let model else {
            throw GemmaRuntimeError.modelLoadFailed
        }

        self.loadedModel = model
        loadedModelURL = modelURL
        return model
    }

    private func makeContext(for model: OpaquePointer) throws -> OpaquePointer {
        var params = llama_context_default_params()
        let threadCount = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        params.n_ctx = GemmaRuntimeLimits.contextWindow
        params.n_batch = GemmaRuntimeLimits.batchSize
        params.n_ubatch = GemmaRuntimeLimits.microBatchSize
        params.n_seq_max = 1
        params.n_threads = threadCount
        params.n_threads_batch = threadCount
        params.offload_kqv = true
        params.no_perf = true

        guard let context = llama_init_from_model(model, params) else {
            throw GemmaRuntimeError.contextCreationFailed
        }

        return context
    }

    private func formatPrompt(
        systemPrompt: String,
        userPrompt: String
    ) throws -> String {
        let systemRole = strdup("system")
        let userRole = strdup("user")
        let systemContent = strdup(systemPrompt)
        let userContent = strdup(userPrompt)
        defer {
            free(systemRole)
            free(userRole)
            free(systemContent)
            free(userContent)
        }

        var messages = [
            llama_chat_message(role: systemRole, content: systemContent),
            llama_chat_message(role: userRole, content: userContent)
        ]

        return try messages.withUnsafeMutableBufferPointer { buffer in
            var output = [CChar](repeating: 0, count: max(4096, (systemPrompt.utf8.count + userPrompt.utf8.count) * 4))
            var written = llama_chat_apply_template(
                nil,
                buffer.baseAddress,
                buffer.count,
                true,
                &output,
                Int32(output.count)
            )

            guard written > 0 else {
                throw GemmaRuntimeError.promptFormattingFailed
            }

            if Int(written) >= output.count {
                output = [CChar](repeating: 0, count: Int(written) + 1)
                written = llama_chat_apply_template(
                    nil,
                    buffer.baseAddress,
                    buffer.count,
                    true,
                    &output,
                    Int32(output.count)
                )
            }

            guard written > 0 else {
                throw GemmaRuntimeError.promptFormattingFailed
            }

            let bytes = output.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func tokenize(
        _ text: String,
        vocab: OpaquePointer
    ) throws -> [llama_token] {
        try text.withCString { cString in
            var tokens = [llama_token](repeating: 0, count: max(256, text.utf8.count + 128))

            let initialCount = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(
                    vocab,
                    cString,
                    Int32(strlen(cString)),
                    buffer.baseAddress,
                    Int32(buffer.count),
                    false,
                    true
                )
            }

            if initialCount >= 0 {
                return Array(tokens.prefix(Int(initialCount)))
            }

            let requiredCount = Int(-initialCount)
            guard requiredCount > 0 else {
                throw GemmaRuntimeError.tokenizationFailed
            }

            tokens = [llama_token](repeating: 0, count: requiredCount)
            let finalCount = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(
                    vocab,
                    cString,
                    Int32(strlen(cString)),
                    buffer.baseAddress,
                    Int32(buffer.count),
                    false,
                    true
                )
            }

            guard finalCount >= 0 else {
                throw GemmaRuntimeError.tokenizationFailed
            }

            return Array(tokens.prefix(Int(finalCount)))
        }
    }

    private func decode(
        _ tokens: [llama_token],
        in context: OpaquePointer
    ) throws {
        guard tokens.isEmpty == false else {
            return
        }

        for chunkStart in stride(from: 0, to: tokens.count, by: Int(GemmaRuntimeLimits.batchSize)) {
            let chunkEnd = min(chunkStart + Int(GemmaRuntimeLimits.batchSize), tokens.count)
            var mutableTokens = Array(tokens[chunkStart..<chunkEnd])
            let status = mutableTokens.withUnsafeMutableBufferPointer { tokenBuffer -> Int32 in
                let batch = llama_batch_get_one(tokenBuffer.baseAddress, Int32(tokenBuffer.count))
                return llama_decode(context, batch)
            }

            guard status == 0 else {
                throw GemmaRuntimeError.decodeFailed(status)
            }
        }
    }

    private func detokenize(
        _ tokens: [llama_token],
        vocab: OpaquePointer
    ) -> String {
        guard tokens.isEmpty == false else {
            return ""
        }

        var output = ""
        var pieceBuffer = [CChar](repeating: 0, count: 512)

        for token in tokens {
            let count = pieceBuffer.withUnsafeMutableBufferPointer { buffer in
                llama_token_to_piece(
                    vocab,
                    token,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    0,
                    true
                )
            }

            guard count > 0 else {
                continue
            }

            output.append(String(decoding: pieceBuffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self))
        }

        return output
    }

    private func makeSampler(temperature: Float) throws -> UnsafeMutablePointer<llama_sampler> {
        if temperature <= 0 {
            guard let sampler = llama_sampler_init_greedy() else {
                throw GemmaRuntimeError.samplerCreationFailed
            }
            return sampler
        }

        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw GemmaRuntimeError.samplerCreationFailed
        }

        guard
            let topK = llama_sampler_init_top_k(40),
            let topP = llama_sampler_init_top_p(0.9, 1),
            let temp = llama_sampler_init_temp(temperature),
            let dist = llama_sampler_init_dist(0)
        else {
            llama_sampler_free(chain)
            throw GemmaRuntimeError.samplerCreationFailed
        }

        llama_sampler_chain_add(chain, topK)
        llama_sampler_chain_add(chain, topP)
        llama_sampler_chain_add(chain, temp)
        llama_sampler_chain_add(chain, dist)
        return chain
    }

    private func validatePromptBudget(
        promptTokenCount: Int,
        maxTokens: Int
    ) throws {
        let reservedCompletionTokens = max(1, maxTokens)
        let maxSupportedPromptTokens = max(
            1,
            Int(GemmaRuntimeLimits.contextWindow) - reservedCompletionTokens - 1
        )

        guard promptTokenCount <= maxSupportedPromptTokens else {
            throw GemmaRuntimeError.promptExceedsContextWindow(
                tokenCount: promptTokenCount,
                maxSupported: maxSupportedPromptTokens
            )
        }
    }
}

#else

actor GemmaRuntime {
    static let shared = GemmaRuntime()
    static let isAvailable = false

    func generateText(
        modelURL: URL,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int = 512,
        temperature: Float = 0
    ) throws -> String {
        throw GemmaRuntimeError.frameworkUnavailable
    }

    func unloadModelForTesting() {}
}

#endif
