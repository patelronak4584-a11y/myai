import SwiftUI
import Security

// MARK: - Models
enum APIType: String, Codable, CaseIterable, Identifiable {
    case openai = "OpenAI-compatible"
    case anthropic = "Anthropic"
    var id: String { rawValue }
}

struct Profile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Default"
    var apiType: APIType = .openai
    var baseURL = "https://api.openai.com/v1"
    var apiKey = ""
    var model = "gpt-4o-mini"
    var systemPrompt = ""
    var temperature = 0.7
    var maxTokens = 1024
    var streaming = true
    var customHeaders = ""
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String
    var content: String
}

// MARK: - Keychain
enum Keychain {
    static func save(_ data: Data, key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var a = q
        a[kSecValueData as String] = data
        SecItemAdd(a as CFDictionary, nil)
    }
    static func load(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

// MARK: - API client
struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct APIClient {
    let profile: Profile
    let log: @MainActor (String) -> Void

    func endpoint() throws -> URL {
        var base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let s: String
        switch profile.apiType {
        case .openai: s = base + "/chat/completions"
        case .anthropic: s = base.hasSuffix("/v1") ? base + "/messages" : base + "/v1/messages"
        }
        guard let u = URL(string: s) else { throw APIError(message: "Base URL ખોટી છે") }
        return u
    }

    func makeRequest(_ messages: [ChatMessage], stream: Bool) throws -> URLRequest {
        var req = URLRequest(url: try endpoint())
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch profile.apiType {
        case .openai:
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        for line in profile.customHeaders.split(separator: "\n") {
            let p = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2 { req.setValue(p[1], forHTTPHeaderField: p[0]) }
        }
        var msgs: [[String: String]] = messages.map { ["role": $0.role, "content": $0.content] }
        var body: [String: Any] = ["model": profile.model,
                                   "stream": stream,
                                   "temperature": profile.temperature,
                                   "max_tokens": profile.maxTokens]
        switch profile.apiType {
        case .openai:
            if !profile.systemPrompt.isEmpty {
                msgs.insert(["role": "system", "content": profile.systemPrompt], at: 0)
            }
        case .anthropic:
            if !profile.systemPrompt.isEmpty { body["system"] = profile.systemPrompt }
        }
        body["messages"] = msgs
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    func send(messages: [ChatMessage], onToken: @MainActor (String) -> Void) async throws {
        let req = try makeRequest(messages, stream: profile.streaming)
        await log("→ POST \(req.url?.absoluteString ?? "")")
        if profile.streaming {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            await log("← HTTP \(code)")
            if code >= 400 {
                var text = ""
                for try await line in bytes.lines { text += line + "\n" }
                await log(String(text.prefix(2000)))
                throw APIError(message: "HTTP \(code): \(text.prefix(500))")
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let d = payload.data(using: .utf8),
                      let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                if let t = delta(j), !t.isEmpty { await onToken(t) }
            }
        } else {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            await log("← HTTP \(code)\n\(text.prefix(2000))")
            if code >= 400 { throw APIError(message: "HTTP \(code): \(text.prefix(500))") }
            guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw APIError(message: "જવાબ સમજાયો નહીં")
            }
            await onToken(full(j))
        }
    }

    private func delta(_ j: [String: Any]) -> String? {
        switch profile.apiType {
        case .openai:
            let c = (j["choices"] as? [[String: Any]])?.first
            return (c?["delta"] as? [String: Any])?["content"] as? String
        case .anthropic:
            guard (j["type"] as? String) == "content_block_delta" else { return nil }
            return (j["delta"] as? [String: Any])?["text"] as? String
        }
    }

    private func full(_ j: [String: Any]) -> String {
        switch profile.apiType {
        case .openai:
            let c = (j["choices"] as? [[String: Any]])?.first
            return (c?["message"] as? [String: Any])?["content"] as? String ?? ""
        case .anthropic:
            let blocks = j["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { $0["text"] as? String }.joined()
        }
    }
}

// MARK: - Store
@MainActor
final class AppStore: ObservableObject {
    @Published var profiles: [Profile] { didSet { saveProfiles() } }
    @Published var activeID: UUID {
        didSet { UserDefaults.standard.set(activeID.uuidString, forKey: "activeID") }
    }
    @Published var messages: [ChatMessage]
    @Published var logs: [String] = []
    @Published var sending = false
    @Published var error: String?
    private var task: Task<Void, Never>?

    init() {
        var loaded = [Profile()]
        if let d = Keychain.load("profiles"),
           let p = try? JSONDecoder().decode([Profile].self, from: d), !p.isEmpty { loaded = p }
        profiles = loaded
        if let s = UserDefaults.standard.string(forKey: "activeID"),
           let u = UUID(uuidString: s), loaded.contains(where: { $0.id == u }) {
            activeID = u
        } else {
            activeID = loaded[0].id
        }
        if let d = UserDefaults.standard.data(forKey: "chat"),
           let m = try? JSONDecoder().decode([ChatMessage].self, from: d) {
            messages = m
        } else {
            messages = []
        }
    }

    var active: Profile { profiles.first { $0.id == activeID } ?? profiles[0] }

    var activeBinding: Binding<Profile> {
        Binding(get: { self.active },
                set: { new in
                    if let i = self.profiles.firstIndex(where: { $0.id == new.id }) { self.profiles[i] = new }
                })
    }

    func saveProfiles() {
        if let d = try? JSONEncoder().encode(profiles) { Keychain.save(d, key: "profiles") }
    }
    func saveChat() {
        if let d = try? JSONEncoder().encode(messages) { UserDefaults.standard.set(d, forKey: "chat") }
    }
    func addLog(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(t)] \(s)")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }
    func addProfile() {
        var p = Profile()
        p.name = "Profile \(profiles.count + 1)"
        profiles.append(p)
        activeID = p.id
    }
    func deleteActive() {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == activeID }
        activeID = profiles[0].id
    }
    func newChat() {
        stop()
        messages = []
        error = nil
        saveChat()
    }
    func stop() { task?.cancel() }

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        error = nil
        messages.append(ChatMessage(role: "user", content: t))
        let history = messages
        messages.append(ChatMessage(role: "assistant", content: ""))
        let idx = messages.count - 1
        sending = true
        let client = APIClient(profile: active, log: { [weak self] s in self?.addLog(s) })
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.send(messages: history) { tok in
                    if idx < self.messages.count { self.messages[idx].content += tok }
                }
            } catch is CancellationError {
            } catch {
                if (error as? URLError)?.code != .cancelled {
                    self.error = error.localizedDescription
                    self.addLog("ERROR: \(error.localizedDescription)")
                }
            }
            if idx < self.messages.count, self.messages[idx].content.isEmpty {
                self.messages.remove(at: idx)
            }
            self.sending = false
            self.saveChat()
        }
    }

    func test() async -> String {
        var p = active
        p.maxTokens = 16
        p.streaming = false
        let client = APIClient(profile: p, log: { [weak self] s in self?.addLog(s) })
        var out = ""
        do {
            try await client.send(messages: [ChatMessage(role: "user", content: "Hi")]) { out += $0 }
            return "✅ કામ કરે છે: \(out)"
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }
}

// MARK: - App
@main
struct MyAIApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup { ChatView().environmentObject(store) }
    }
}

func md(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

// MARK: - Chat
struct Bubble: View {
    let m: ChatMessage
    var isUser: Bool { m.role == "user" }
    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(md(m.content.isEmpty ? "…" : m.content))
                .textSelection(.enabled)
                .padding(10)
                .background(isUser ? Color.blue.opacity(0.85) : Color(.secondarySystemBackground))
                .foregroundColor(isUser ? .white : .primary)
                .cornerRadius(14)
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    @State private var input = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if store.messages.isEmpty {
                                Text(store.active.apiKey.isEmpty
                                     ? "⚙️ Settings માં Base URL અને API Key નાખો"
                                     : "કંઈક પૂછો…")
                                    .foregroundColor(.secondary)
                                    .padding(.top, 80)
                            }
                            ForEach(store.messages) { m in Bubble(m: m).id(m.id) }
                            if let e = store.error {
                                Text(e).font(.footnote).foregroundColor(.red).padding(.horizontal)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding()
                    }
                    .onChange(of: store.messages) { _ in proxy.scrollTo("bottom") }
                    .onChange(of: store.error) { _ in proxy.scrollTo("bottom") }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("સંદેશ લખો", text: $input, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        if store.sending { store.stop() } else { store.send(input); input = "" }
                    } label: {
                        Image(systemName: store.sending ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 32))
                    }
                }
                .padding(8)
            }
            .navigationTitle("MyAI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { store.newChat() } label: { Image(systemName: "square.and.pencil") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(store)
            }
        }
    }
}

// MARK: - Settings
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var testResult = ""
    @State private var testing = false

    private var b: Binding<Profile> { store.activeBinding }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    Picker("Active", selection: $store.activeID) {
                        ForEach(store.profiles) { Text($0.name).tag($0.id) }
                    }
                    Button("નવી Profile ઉમેરો") { store.addProfile() }
                    if store.profiles.count > 1 {
                        Button("આ Profile કાઢી નાખો", role: .destructive) { store.deleteActive() }
                    }
                }
                Section("API") {
                    TextField("Profile નામ", text: b.name)
                    Picker("Type", selection: b.apiType) {
                        ForEach(APIType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Base URL", text: b.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API Key", text: b.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model", text: b.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(testing ? "ચકાસી રહ્યા છીએ…" : "Test connection") {
                        testing = true
                        testResult = ""
                        Task {
                            testResult = await store.test()
                            testing = false
                        }
                    }
                    if !testResult.isEmpty { Text(testResult).font(.footnote) }
                }
                Section {
                    NavigationLink("Developer Options") { DeveloperView() }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct DeveloperView: View {
    @EnvironmentObject var store: AppStore
    private var b: Binding<Profile> { store.activeBinding }

    var body: some View {
        Form {
            Section("Generation") {
                VStack(alignment: .leading) {
                    Text("Temperature: \(b.wrappedValue.temperature, specifier: "%.2f")")
                    Slider(value: b.temperature, in: 0...2)
                }
                Stepper("Max tokens: \(b.wrappedValue.maxTokens)", value: b.maxTokens, in: 16...32000, step: 256)
                Toggle("Streaming", isOn: b.streaming)
            }
            Section("System prompt") {
                TextEditor(text: b.systemPrompt).frame(minHeight: 100)
            }
            Section("Custom headers (Key: Value, દરેક લીટીમાં એક)") {
                TextEditor(text: b.customHeaders)
                    .frame(minHeight: 70)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Request log") {
                Button("Log સાફ કરો") { store.logs.removeAll() }
                ForEach(Array(store.logs.reversed().enumerated()), id: \.offset) { item in
                    Text(item.element).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Developer Options")
    }
}
