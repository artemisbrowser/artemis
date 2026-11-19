// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation
import FoundationModels
import os

/// an OpenAI-compatible server the user added. its API key is a Keychain item under `id`
nonisolated struct IntelligenceEngine: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// what `models` and `chat/completions` hang off, usually ending `/v1`
    var baseURL: URL
    var model: String
    /// words of page text one request carries
    var wordBudget: Int

    enum Preset: String, CaseIterable, Identifiable {
        case ollama = "Ollama"
        case lmStudio = "LM Studio"
        case openAI = "OpenAI"
        case openRouter = "OpenRouter"
        case custom = "Custom"

        var id: Self { self }

        var baseURL: String {
            switch self {
            case .ollama: "http://localhost:11434/v1"
            case .lmStudio: "http://localhost:1234/v1"
            case .openAI: "https://api.openai.com/v1"
            case .openRouter: "https://openrouter.ai/api/v1"
            case .custom: ""
            }
        }
    }

    var host: String { baseURL.host() ?? baseURL.absoluteString }
    var isOnThisMac: Bool { ["localhost", "127.0.0.1", "::1"].contains(host) }

    static let storageKey = "intelligenceEngines"

    static var all: [IntelligenceEngine] {
        get {
            UserDefaults.standard.data(forKey: storageKey)
                .flatMap { try? JSONDecoder().decode([IntelligenceEngine].self, from: $0) } ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: storageKey) }
    }

    static let keychain = "\(Keychain.owner) Intelligence"

    var key: String {
        get { Keychain.secret(Self.keychain, id.uuidString).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        nonmutating set {
            if newValue.isEmpty {
                Keychain.delete(Self.keychain, id.uuidString)
            } else {
                Keychain.put(Self.keychain, id.uuidString, Data(newValue.utf8))
            }
        }
    }

    struct Refusal: Error {
        var status: Int
        var body: String
    }

    private static let session = URLSession(configuration: .ephemeral)

    private func send(_ path: String, key: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 120)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Refusal(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    /// the model ids the server offers to `key`
    func models(key: String) async throws -> [String] {
        struct List: Decodable {
            struct Model: Decodable { var id: String }
            var data: [Model]
        }
        return try JSONDecoder().decode(List.self, from: try await send("models", key: key)).data.map(\.id).sorted()
    }

    private struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        var choices: [Choice]
    }

    /// how many of `generate`'s optional steps each server refused, in the order they are dropped
    private static let refused = OSAllocatedUnfairLock(initialState: [UUID: Int]())

    /// `seed` nil asks for the likeliest answer; a seed samples, so unsure answers differ between seeds
    func generate<T: Generable & Sendable>(
        _ type: T.Type, instructions: String, prompt: String, seed: UInt64?
    ) async throws -> T {
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(T.generationSchema))
        let shape = String(
            decoding: try JSONSerialization.data(withJSONObject: schema, options: .sortedKeys), as: UTF8.self)
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "\(instructions)\n\nReply with one JSON object matching this schema and nothing else:\n\(shape)",
                ],
                ["role": "user", "content": prompt],
            ],
        ]
        let format: [String: Any] = [
            "response_format": ["type": "json_schema", "json_schema": ["name": "reply", "schema": schema]]
        ]
        var sampled = format.merging(["temperature": seed == nil ? 0 : 1]) { $1 }
        if let seed { sampled["seed"] = seed }
        // dropped first to last on a 400: no reasoning, the sampling, the format
        let extras = [sampled.merging(["reasoning_effort": "none"]) { $1 }, sampled, format, [:]]
        let key = key
        var step = Self.refused.withLock { $0[id] ?? 0 }
        var data: Data?
        while data == nil {
            do {
                data = try await send("chat/completions", key: key, body: body.merging(extras[step]) { $1 })
            } catch let refusal as Refusal where refusal.status == 400 && step < extras.count - 1 {
                step += 1
            }
        }
        Self.refused.withLock { $0[id] = step }
        var answer = Substring(try JSONDecoder().decode(Reply.self, from: data!).choices.first?.message.content ?? "")
        // a reasoning model's thoughts come first, and a chat model may fence the object
        if let thoughts = answer.range(of: "</think>") { answer = answer[thoughts.upperBound...] }
        guard let open = answer.firstIndex(of: "{"), let close = answer.lastIndex(of: "}"), open < close else {
            throw Refusal(status: 200, body: String(answer.prefix(300)))
        }
        return try T(GeneratedContent(json: String(answer[open...close])))
    }
}
