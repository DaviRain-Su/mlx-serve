import SwiftUI

private struct ContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ScrollViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Thread-safe timestamp used by the agent-loop stream watchdog to decide if the
/// current iteration has stalled (no SSE events for too long).
final class StreamProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Date = Date()
    func bump() {
        lock.lock(); last = Date(); lock.unlock()
    }
    func idleSeconds() -> Double {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var server: ServerManager
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ChatSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            if let sessionId = appState.activeChatId,
               appState.chatSessions.contains(where: { $0.id == sessionId }) {
                ChatDetailView(sessionId: sessionId)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text("Start a conversation")
                        .foregroundStyle(.secondary)
                    Button("New Chat") {
                        _ = appState.newChatSession()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .onAppear {
            // Menu bar apps need explicit activation for keyboard focus
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

// MARK: - Sidebar

struct ChatSidebar: View {
    @EnvironmentObject var appState: AppState
    @State private var hoveredSessionId: UUID?

    var body: some View {
        List(selection: $appState.activeChatId) {
            ForEach(appState.chatSessions) { session in
                let isSelected = session.id == appState.activeChatId
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .white : .primary)
                        Text(relativeTime(session.updatedAt))
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.5))
                    }
                    Spacer(minLength: 4)
                    if hoveredSessionId == session.id {
                        Button {
                            appState.deleteSession(session.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete chat")
                    }
                }
                .tag(session.id)
                .onHover { isHovered in
                    hoveredSessionId = isHovered ? session.id : nil
                }
                .listRowBackground(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor)
                                .padding(.horizontal, 6)
                        } else {
                            Color.clear
                        }
                    }
                )
                .listRowSeparator(.visible)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        appState.deleteSession(session.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                _ = appState.newChatSession()
            } label: {
                Label("New Chat", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(10)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}

// MARK: - Chat Detail

struct ChatDetailView: View {
    let sessionId: UUID
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var toolExecutor: ToolExecutor
    @State private var inputText = ""
    @State private var isGenerating = false
    @State private var enableThinking = false
    @State private var isAgentMode = false
    @State private var executingPlanMessageId: UUID?
    @State private var generationTask: Task<Void, Never>?
    @State private var isNearBottom = true
    @State private var scrollViewHeight: CGFloat = 0
    @State private var contentBottom: CGFloat = 0
    @State private var scrollMonitor: Any?
    @State private var pendingImages: [NSImage] = []
    @FocusState private var inputFocused: Bool


    private var session: ChatSession? {
        appState.chatSessions.first { $0.id == sessionId }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(session?.messages ?? []) { message in
                            // Hide tool response messages (role: system with toolCallId)
                            if message.toolCallId == nil {
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        // Bottom anchor — its position relative to the scroll viewport
                        // tells us whether the user has scrolled to the bottom.
                        Color.clear.frame(height: 1).id("bottom")
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ContentBottomKey.self,
                                        value: geo.frame(in: .named("chatScroll")).maxY
                                    )
                                }
                            )
                    }
                    .padding(16)
                }
                .coordinateSpace(name: "chatScroll")
                .background(
                    GeometryReader { scrollFrame in
                        Color.clear.preference(
                            key: ScrollViewHeightKey.self,
                            value: scrollFrame.size.height
                        )
                    }
                )
                .onPreferenceChange(ScrollViewHeightKey.self) { scrollViewHeight = $0 }
                .onPreferenceChange(ContentBottomKey.self) { bottom in
                    contentBottom = bottom
                    guard scrollViewHeight > 0 else { return }
                    // Re-engage auto-scroll when content bottom is near viewport bottom
                    if bottom - scrollViewHeight < 60 { isNearBottom = true }
                }
                .onChange(of: session?.messages.count) { _, _ in
                    if isNearBottom { scrollToBottom(proxy) }
                }
                .onChange(of: session?.messages.last?.content) { _, _ in
                    if isNearBottom { scrollToBottom(proxy) }
                }
                .overlay(alignment: .trailing) {
                    // Right-edge strip: accent tint when auto-scroll is on, fades out when off.
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(isNearBottom ? 0.4 : 0))
                        .frame(width: 4)
                        .padding(.vertical, 4)
                        .animation(.easeInOut(duration: 0.3), value: isNearBottom)
                        .allowsHitTesting(false)
                }
            }

            Divider()

            // Context usage monitor
            if let usage = contextUsage, usage.promptTokens > 0 {
                ContextMonitor(promptTokens: usage.promptTokens, contextLength: usage.contextLength, maxTokens: appState.maxTokens)
            }

            // Input area — iMessage style
            VStack(spacing: 4) {
                // Pending image thumbnails
                if !pendingImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(pendingImages.enumerated()), id: \.offset) { idx, img in
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Button {
                                        pendingImages.remove(at: idx)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.white)
                                            .background(Circle().fill(.black.opacity(0.5)))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 4, y: -4)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(height: 64)
                }

                HStack(alignment: .bottom, spacing: 8) {
                    // Image attachment button
                    Button { pickImage() } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Attach image")

                    // Dark pill input
                    TextField("Message", text: $inputText, axis: .vertical)
                        .font(.body)
                        .textFieldStyle(.plain)
                        .lineLimit(1...15)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .focused($inputFocused)
                        .disabled(server.status != .running)
                        .onKeyPress(keys: [.return, .init("\u{03}")], phases: .down) { press in
                            if press.modifiers.contains(.shift) {
                                inputText += "\n"
                                return .handled
                            }
                            if !isGenerating {
                                sendMessage()
                            }
                            return .handled
                        }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                inputFocused = true
                            }
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        )

                    Button {
                        if isGenerating {
                            stopGenerating()
                        } else {
                            sendMessage()
                        }
                    } label: {
                        Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(isGenerating ? .red : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(server.status != .running || (inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty && !isGenerating))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onDrop(of: [.image], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadObject(ofClass: NSImage.self) { image, _ in
                    if let image = image as? NSImage {
                        DispatchQueue.main.async { pendingImages.append(image) }
                    }
                }
            }
            return true
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if isAgentMode {
                    WorkingDirectoryIndicator(path: workingDirectoryBinding)
                }
            }
            ToolbarItem(placement: .automatic) {
                if isAgentMode {
                    Button {
                        let path = NSString(string: "~/.mlx-serve").expandingTildeInPath
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    } label: {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 12))
                    }
                    .help("Agent Skills Folder")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { enableThinking.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                            .font(.system(size: 11, weight: .medium))
                        Text("Think")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(enableThinking ? .white : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(enableThinking ? .blue : Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Thinking Mode (\(enableThinking ? "ON" : "OFF"))")
                .padding(.leading, 8)
                .padding(.trailing, 4)
            }
            ToolbarItem(placement: .automatic) {
                Button { isAgentMode.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wrench")
                            .font(.system(size: 11, weight: .medium))
                        Text("Agent")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(isAgentMode ? .white : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isAgentMode ? .orange : Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Agent Mode (\(isAgentMode ? "ON" : "OFF"))")
            }
            ToolbarItem(placement: .automatic) {
                Circle()
                    .fill(server.status == .running ? .green : .red)
                    .frame(width: 8, height: 8)
                    .padding(.horizontal, 8)
                    .help(server.status == .running ? "Server running" : "Server stopped")
            }
        }
        .onAppear {
            inputFocused = true
            isAgentMode = session?.mode == .agent
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                if event.scrollingDeltaY > 0 {
                    // Scrolling up — disengage auto-scroll
                    isNearBottom = false
                } else if event.scrollingDeltaY < -1 {
                    // Scrolling down — re-engage if content bottom is near viewport bottom.
                    // The preference handler catches this when content changes, but during
                    // generation pauses the user needs scroll events to re-engage.
                    if scrollViewHeight > 0 && contentBottom - scrollViewHeight < 80 {
                        isNearBottom = true
                    }
                }
                return event
            }
        }
        .onDisappear {
            generationTask?.cancel()
            generationTask = nil
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }
        .onChange(of: isAgentMode) { _, newValue in
            if let idx = appState.chatSessions.firstIndex(where: { $0.id == sessionId }) {
                appState.chatSessions[idx].mode = newValue ? .agent : .chat
            }
        }
        .onChange(of: isGenerating) { _, generating in
            if !generating { inputFocused = true }
        }
    }

    // MARK: - Image Helpers

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let image = NSImage(contentsOf: url) {
                    pendingImages.append(image)
                }
            }
        }
    }

    /// Convert NSImage to JPEG data suitable for API transport.
    private static func nsImageToJPEG(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }
        return jpeg
    }

    /// Convert pending NSImages to ChatImage array, clearing the pending list.
    private func consumePendingImages() -> [ChatImage]? {
        guard !pendingImages.isEmpty else { return nil }
        let chatImages = pendingImages.compactMap { img -> ChatImage? in
            guard let data = Self.nsImageToJPEG(img) else { return nil }
            return ChatImage(data: data)
        }
        pendingImages = []
        return chatImages.isEmpty ? nil : chatImages
    }

    /// Build OpenAI-style content blocks for a message with images.
    /// Images are preprocessed to raw float32 pixel data for the vision encoder.
    private static func buildMultimodalContent(text: String, images: [ChatImage]) -> Any {
        var blocks: [[String: Any]] = images.compactMap { img in
            // Preprocess image for vision encoder (768x768 float32 CHW)
            if let pixelData = ImagePreprocessor.preprocess(img.data) {
                return [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/x-mlx-pixels;base64,\(pixelData.base64EncodedString())"
                    ] as [String: Any]
                ]
            }
            // Fallback: send JPEG if preprocessing fails
            return [
                "type": "image_url",
                "image_url": ["url": img.base64URL] as [String: Any]
            ]
        }
        if !text.isEmpty {
            blocks.append(["type": "text", "text": text])
        }
        return blocks
    }

    // MARK: - Helpers

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }


    /// Latest context usage from the most recent assistant message with token data.
    private var contextUsage: (promptTokens: Int, contextLength: Int)? {
        guard let messages = session?.messages else { return nil }
        if let last = messages.last(where: { $0.promptTokens != nil && $0.promptTokens! > 0 }) {
            let ctxLen = AgentEngine.effectiveContextLength(
                appContextSize: appState.contextSize,
                modelContextLength: server.modelInfo?.contextLength
            )
            return (promptTokens: last.promptTokens!, contextLength: ctxLen)
        }
        return nil
    }

    private var workingDirectoryBinding: Binding<String?> {
        Binding(
            get: { appState.chatSessions.first { $0.id == sessionId }?.workingDirectory },
            set: { newValue in
                if let idx = appState.chatSessions.firstIndex(where: { $0.id == sessionId }) {
                    appState.chatSessions[idx].workingDirectory = newValue
                    if let dir = newValue {
                        appState.agentMemory.recordDirectory(dir)
                    }
                }
            }
        )
    }

    // MARK: - Stop Generation

    private func stopGenerating() {
        generationTask?.cancel()
        generationTask = nil
        appState.updateLastMessage(in: sessionId, streaming: false)
        appState.saveChatHistory()
        isGenerating = false
    }

    // MARK: - Send Message

    private func sendMessage() {
        isNearBottom = true // snap to bottom on send
        if isAgentMode {
            sendAgentMessage()
            return
        }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachedImages = consumePendingImages()
        guard !text.isEmpty || attachedImages != nil, !isGenerating, server.status == .running else { return }
        inputText = ""

        var userMsg = ChatMessage(role: .user, content: text)
        userMsg.images = attachedImages
        appState.appendMessage(to: sessionId, message: userMsg)

        var assistantMsg = ChatMessage(role: .assistant, content: "")
        assistantMsg.isStreaming = true
        appState.appendMessage(to: sessionId, message: assistantMsg)

        isGenerating = true
        let api = APIClient()

        // Strip images from old messages — server only processes the last user message's images.
        // Re-sending old images wastes bandwidth and memory.
        let messages = (session?.messages ?? []).map { msg -> [String: Any] in
            var dict: [String: Any] = ["role": msg.role.rawValue, "content": msg.content]
            if msg.role == .assistant && msg.content.isEmpty { dict.removeValue(forKey: "content") }
            return dict
        }.dropLast() // Drop the empty assistant message we just added
        // Build last user message with potential images
        var lastUserDict: [String: Any] = ["role": "user"]
        if let imgs = attachedImages, !imgs.isEmpty {
            lastUserDict["content"] = Self.buildMultimodalContent(text: text, images: imgs)
        } else {
            lastUserDict["content"] = text
        }
        let messagesArray = Array(messages) + [lastUserDict]

        generationTask = Task {
            do {
                let stream = api.streamChat(
                    port: server.port,
                    messages: messagesArray,
                    maxTokens: appState.maxTokens,
                    enableThinking: enableThinking
                )
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .content(let text):
                        appState.updateLastMessage(in: sessionId, content: text)
                    case .reasoning(let text):
                        appState.updateLastMessage(in: sessionId, reasoning: text)
                    case .usage(let usage):
                        appState.updateLastMessage(in: sessionId, usage: usage)
                    case .toolCalls:
                        break
                    case .maxTokensReached:
                        appState.updateLastMessage(in: sessionId, content: "\n\n⚠️ *Output truncated — max tokens (\(appState.maxTokens)) reached.*")
                    case .done:
                        break
                    }
                }
            } catch is CancellationError {
                // Stopped by user
            } catch {
                print("[ChatView] Chat error: \(error)")
                try? "Chat error: \(error)\n".write(toFile: NSString(string: "~/.mlx-serve/debug.log").expandingTildeInPath, atomically: true, encoding: .utf8)
                appState.updateLastMessage(in: sessionId, content: "\n\n[Error: \(error.localizedDescription)]")
            }
            appState.updateLastMessage(in: sessionId, streaming: false)
            appState.saveChatHistory()
            isGenerating = false
            generationTask = nil
        }
    }

    // MARK: - Agent Mode (Native Tool Calling)

    private func sendAgentMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachedImages = consumePendingImages()
        guard !text.isEmpty || attachedImages != nil, !isGenerating, server.status == .running else { return }
        inputText = ""

        var userMsg = ChatMessage(role: .user, content: text)
        userMsg.images = attachedImages
        appState.appendMessage(to: sessionId, message: userMsg)

        isGenerating = true
        let api = APIClient()
        let workDir = session?.workingDirectory

        generationTask = Task {
            do {
                try await runAgentLoop(api: api, workingDirectory: workDir)
            } catch is CancellationError {
                // Stopped by user
            } catch {
                print("[ChatView] Agent error: \(error)")
                try? "Agent error: \(error)\n".write(toFile: NSString(string: "~/.mlx-serve/debug.log").expandingTildeInPath, atomically: true, encoding: .utf8)
                var errorMsg = ChatMessage(role: .assistant, content: "[Error: \(error.localizedDescription)]")
                errorMsg.isStreaming = false
                appState.appendMessage(to: sessionId, message: errorMsg)
            }
            appState.saveChatHistory()
            isGenerating = false
            generationTask = nil
        }
    }


    /// Agent loop: call model with tools (streaming), execute tool calls, feed results back, repeat.
    /// Stops when the model responds with content (no tool calls) or after 150 iterations.
    private func runAgentLoop(api: APIClient, workingDirectory initialWorkDir: String?) async throws {
        var workingDirectory = initialWorkDir
        let maxIterations = 150
        var padRetries = 0
        let padRetryPolicy = RetryPolicy.aggressive
        let repetition = AgentEngine.RepetitionTracker()
        var truncationRetries = 0
        // One retry when the model exits with a malformed/ghost tool-call tag
        // in its content instead of a proper finish — re-prompt for a clean
        // plain-text summary so the user isn't left staring at `<|tool_call>…`.
        var completionRetries = 0

        for iteration in 0..<maxIterations {
            try Task.checkCancellation()

            // Build message history for API
            let contextLength = AgentEngine.effectiveContextLength(
                appContextSize: appState.contextSize,
                modelContextLength: server.modelInfo?.contextLength
            )
            var history = AgentEngine.buildAgentHistory(
                messages: session?.messages ?? [],
                contextLength: contextLength,
                maxTokens: appState.maxTokens,
                buildMultimodalContent: Self.buildMultimodalContent
            )
            let userMsg = history.last { ($0["role"] as? String) == "user" }?["content"] as? String ?? ""
            let skills = AgentPrompt.skillManager.matchingSkills(for: userMsg)
            var systemPrompt = AgentPrompt.systemPrompt + skills + AgentPrompt.memory + appState.agentMemory.contextSnippet()
            if let wd = workingDirectory {
                systemPrompt += AgentEngine.workingDirectoryContext(wd)
            }
            var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
            // Some models (e.g. Gemma 4 E4B) can't generate after tool results without
            // a user message. Add a nudge so the model knows to synthesize a response —
            // asks explicitly for a short plain-text summary when finished so the user
            // never sees a conversation that ends on a bare tool-call echo.
            if let lastRole = history.last?["role"] as? String, lastRole == "tool" {
                history.append(["role": "user", "content": "Continue. If the task is complete, reply with a short plain-text summary for the user (what got done, where it lives, any caveats) — no tool calls, no JSON. If more work is needed, make the next tool call."])
            }
            messages.append(contentsOf: history)

            AgentEngine.dumpDebugRequest(messages: messages, maxTokens: appState.maxTokens)

            // Add streaming assistant message
            var streamMsg = ChatMessage(role: .assistant, content: "")
            streamMsg.isStreaming = true
            appState.appendMessage(to: sessionId, message: streamMsg)

            // Stream model response with tools
            var receivedToolCalls: [APIClient.ToolCall] = []
            var maxTokensHit = false
            let stream = api.streamChat(
                port: server.port,
                messages: messages,
                maxTokens: appState.maxTokens,
                temperature: 0.7,
                enableThinking: enableThinking,
                toolsJSON: AgentPrompt.toolDefinitionsJSON
            )

            // Watchdog: cancel the stream if no SSE event arrives within 90s.
            // Server-side thinking buffering for tool-enabled requests can block the
            // client for many seconds; a genuine stall (KV cache poison, sampling
            // loop, network hang) would otherwise hang forever until the user hits Stop.
            let watchdogSeconds: Double = 90
            let lastEventAt = StreamProgressClock()
            var streamStalled = false
            let streamTask = Task<(tcs: [APIClient.ToolCall], maxHit: Bool), Error> {
                var tcs: [APIClient.ToolCall] = []
                var maxHit = false
                for try await event in stream {
                    try Task.checkCancellation()
                    lastEventAt.bump()
                    switch event {
                    case .content(let text):
                        appState.updateLastMessage(in: sessionId, content: text)
                    case .reasoning(let text):
                        appState.updateLastMessage(in: sessionId, reasoning: text)
                    case .usage(let usage):
                        appState.updateLastMessage(in: sessionId, usage: usage)
                    case .toolCalls(let calls):
                        tcs = calls
                    case .maxTokensReached:
                        maxHit = true
                        appState.updateLastMessage(in: sessionId, content: "\n\n⚠️ *Output truncated — max tokens (\(appState.maxTokens)) reached. Try breaking the task into smaller steps.*")
                    case .done:
                        break
                    }
                }
                return (tcs, maxHit)
            }
            let watchdog = Task {
                while !streamTask.isCancelled {
                    try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                    if Task.isCancelled { return }
                    if lastEventAt.idleSeconds() > watchdogSeconds {
                        streamStalled = true
                        streamTask.cancel()
                        return
                    }
                }
            }
            // Unstructured child tasks don't inherit cancellation from the outer
            // agent-loop task, so wire the Stop button through explicitly.
            do {
                let result = try await withTaskCancellationHandler {
                    try await streamTask.value
                } onCancel: {
                    streamTask.cancel()
                    watchdog.cancel()
                }
                receivedToolCalls = result.tcs
                maxTokensHit = result.maxHit
            } catch is CancellationError {
                watchdog.cancel()
                if !streamStalled { throw CancellationError() }
            } catch {
                watchdog.cancel()
                throw error
            }
            watchdog.cancel()
            appState.updateLastMessage(in: sessionId, streaming: false)

            // Watchdog-triggered stall: surface a clear error and stop the loop.
            // The user can simply resend their question — server state is preserved.
            if streamStalled {
                if let sIdx = appState.chatSessions.firstIndex(where: { $0.id == sessionId }),
                   !appState.chatSessions[sIdx].messages.isEmpty {
                    let mIdx = appState.chatSessions[sIdx].messages.count - 1
                    appState.chatSessions[sIdx].messages[mIdx].failedRetry = true
                }
                let errorMsg = ChatMessage(
                    role: .assistant,
                    content: "⚠️ The model didn't produce a response within \(Int(watchdogSeconds))s. Try resending your message, simplifying the request, or restarting the server."
                )
                appState.appendMessage(to: sessionId, message: errorMsg)
                return
            }

            // Truncation recovery: if max_tokens was hit AND tool calls were received,
            // the tool call args are likely truncated (incomplete JSON). Don't execute them —
            // mark the broken message as non-replayable (preserves reasoning in the UI)
            // and nudge the model to try again more concisely.
            if maxTokensHit && !receivedToolCalls.isEmpty && truncationRetries < 2 {
                truncationRetries += 1
                if let sIdx = appState.chatSessions.firstIndex(where: { $0.id == sessionId }),
                   !appState.chatSessions[sIdx].messages.isEmpty {
                    let mIdx = appState.chatSessions[sIdx].messages.count - 1
                    appState.chatSessions[sIdx].messages[mIdx].failedRetry = true
                    appState.chatSessions[sIdx].messages[mIdx].toolCalls = nil
                }
                let nudge = ChatMessage(role: .user, content: "[System: Your last response was cut off because the output was too long. The tool call was NOT executed. To avoid this, write shorter responses: use shell with heredoc (cat << 'EOF' > file) for file content instead of writeFile, or break large files into smaller pieces.]")
                appState.appendMessage(to: sessionId, message: nudge)
                continue
            }

            // Check for pad-only or empty responses — retry limited times.
            // Mark the empty message as failedRetry so it's hidden from API history
            // but its reasoning (if any) stays visible in the UI.
            if receivedToolCalls.isEmpty {
                let lastContent = appState.chatSessions
                    .first(where: { $0.id == sessionId })?.messages.last?.content ?? ""
                let cleaned = lastContent
                    .replacingOccurrences(of: "<pad>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty {
                    if let sIdx = appState.chatSessions.firstIndex(where: { $0.id == sessionId }),
                       !appState.chatSessions[sIdx].messages.isEmpty {
                        let mIdx = appState.chatSessions[sIdx].messages.count - 1
                        appState.chatSessions[sIdx].messages[mIdx].failedRetry = true
                    }
                    padRetries += 1
                    if padRetries <= padRetryPolicy.maxRetries {
                        let delay = padRetryPolicy.delay(for: padRetries)
                        try? await Task.sleep(nanoseconds: delay)
                        continue
                    }
                    let errorMsg = ChatMessage(role: .assistant, content: "The model couldn't generate a response. Try rephrasing or starting a new chat.")
                    appState.appendMessage(to: sessionId, message: errorMsg)
                    return
                }
            }

            // If no tool calls, we're done — but make sure the user sees a
            // clean completion text. The model sometimes exits with a ghost
            // tool call (malformed <|tool_call>...<tool_call|> or <tool_call>
            // with bad args that didn't parse) as its final content; that's
            // ugly and uninformative. When we detect one, mark the garbled
            // turn as failedRetry (hidden from API history) and ask the model
            // for a plain-text summary before returning control to the user.
            if receivedToolCalls.isEmpty {
                let lastContent = appState.chatSessions
                    .first(where: { $0.id == sessionId })?.messages.last?.content ?? ""
                let looksLikeGhostToolCall = lastContent.contains("<|tool_call>") ||
                    lastContent.contains("<tool_call>") ||
                    lastContent.contains("<tool_call|>") ||
                    lastContent.contains("<function=")
                if looksLikeGhostToolCall && completionRetries < 1 {
                    completionRetries += 1
                    if let sIdx = appState.chatSessions.firstIndex(where: { $0.id == sessionId }),
                       !appState.chatSessions[sIdx].messages.isEmpty {
                        let mIdx = appState.chatSessions[sIdx].messages.count - 1
                        appState.chatSessions[sIdx].messages[mIdx].failedRetry = true
                    }
                    let nudge = ChatMessage(role: .user, content: "[System: your last response contained a malformed tool-call tag. If you meant to call a tool, call it with proper JSON. If the task is complete, respond with a short plain-text summary of what you did — no tool tags, no JSON — just a sentence or two for the user.]")
                    appState.appendMessage(to: sessionId, message: nudge)
                    continue
                }
                return
            }

            // Track repetition for this round
            repetition.track(toolCalls: receivedToolCalls)

            // Store tool calls on the assistant message for history replay
            if let sIdx = appState.chatSessions.firstIndex(where: { $0.id == sessionId }),
               !appState.chatSessions[sIdx].messages.isEmpty {
                let mIdx = appState.chatSessions[sIdx].messages.count - 1
                appState.chatSessions[sIdx].messages[mIdx].toolCalls = receivedToolCalls.map { tc in
                    let argsJson = (try? JSONSerialization.data(withJSONObject: tc.arguments))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return SerializedToolCall(id: tc.id, name: tc.name, arguments: argsJson)
                }
            }

            // Show tool call summary as display-only message
            let callSummary = receivedToolCalls.map { tc in
                let args = tc.arguments.map { "\($0.key): \($0.value.prefix(80))" }.joined(separator: ", ")
                let display = args.isEmpty ? tc.rawArguments.prefix(200) : args[...]
                return "**\(tc.name)**(\(display))"
            }.joined(separator: "\n")
            var summaryMsg = ChatMessage(role: .assistant, content: callSummary)
            summaryMsg.isAgentSummary = true
            appState.appendMessage(to: sessionId, message: summaryMsg)

            // Execute each tool call
            for tc in receivedToolCalls {
                try Task.checkCancellation()
                let result = await AgentEngine.executeToolCall(
                    tc, workingDirectory: &workingDirectory,
                    repetition: repetition, iteration: iteration,
                    agentMemory: appState.agentMemory
                )

                // Show result in chat (display-only)
                var resultMsg = ChatMessage(role: .assistant, content: "**\(result.name)** → \(String(result.output.prefix(500)))")
                resultMsg.isAgentSummary = true
                appState.appendMessage(to: sessionId, message: resultMsg)

                // Store tool result as tool role message
                var toolMsg = ChatMessage(role: .system, content: "")
                toolMsg.toolCallId = result.id
                toolMsg.toolName = result.name

                // Extract screenshot image data and attach as vision input
                if result.name == "browse" && result.output.contains("data:image/jpeg;base64,") {
                    if let range = result.output.range(of: "data:image/jpeg;base64,") {
                        let remainder = result.output[range.upperBound...]
                        let b64End = remainder.firstIndex(of: "\n") ?? remainder.endIndex
                        let b64 = String(remainder[..<b64End])
                        if let jpegData = Data(base64Encoded: b64),
                           let chatImage = ChatImage(data: jpegData) as ChatImage? {
                            toolMsg.images = [chatImage]
                            toolMsg.content = "[screenshot captured]"
                        } else {
                            toolMsg.content = AgentEngine.truncateWithOverflow(result.output, toolCallId: result.id, toolName: result.name)
                        }
                    } else {
                        toolMsg.content = AgentEngine.truncateWithOverflow(result.output, toolCallId: result.id, toolName: result.name)
                    }
                } else {
                    toolMsg.content = AgentEngine.truncateWithOverflow(result.output, toolCallId: result.id, toolName: result.name)
                }
                appState.appendMessage(to: sessionId, message: toolMsg)
            }
        }

        // Max iterations reached
        let msg = ChatMessage(role: .assistant, content: "(Agent stopped after \(maxIterations) tool call rounds)")
        appState.appendMessage(to: sessionId, message: msg)
    }

}

// MARK: - Context Monitor

struct ContextMonitor: View {
    let promptTokens: Int
    let contextLength: Int
    let maxTokens: Int

    private var usageRatio: Double {
        guard contextLength > 0 else { return 0 }
        return Double(promptTokens) / Double(contextLength)
    }

    private var generationBudget: Int {
        let remaining = max(0, contextLength - promptTokens)
        return min(remaining, maxTokens)
    }

    private var barColor: Color {
        if usageRatio > 0.80 { return .red }
        if usageRatio > 0.60 { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor.opacity(0.7))
                        .frame(width: geo.size.width * min(1.0, usageRatio))
                }
            }
            .frame(height: 4)

            HStack {
                Text("\(promptTokens)/\(contextLength) tokens (\(Int(usageRatio * 100))%)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("gen: \(generationBudget)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(generationBudget < 2048 ? .red : generationBudget < 4096 ? .orange : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

// MARK: - Generating Indicator

/// Animated indicator shown while the model is generating, with live GPU and memory stats.
struct GeneratingIndicator: View {
    @State private var gpuPercent: Int = 0
    @State private var memPercent: Int = 0
    @State private var whimsy: String = Self.randomWhimsy()
    @State private var timer: Timer?
    @State private var startDate = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let outerAngle = elapsed * 120  // degrees per second
            let innerAngle = -elapsed * 168 // counter-rotate, slightly faster

            HStack(spacing: 8) {
                // Spinning arcs — continuous, no reset
                ZStack {
                    // Outer arc — GPU usage mapped to arc length
                    Circle()
                        .trim(from: 0, to: max(0.1, Double(gpuPercent) / 100.0))
                        .stroke(gpuColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(outerAngle))

                    // Inner arc — memory
                    Circle()
                        .trim(from: 0, to: max(0.1, Double(memPercent) / 100.0))
                        .stroke(memColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(innerAngle))

                    // Center dot pulses with GPU activity
                    Circle()
                        .fill(gpuColor)
                        .frame(width: 3, height: 3)
                        .scaleEffect(1.0 + 0.3 * sin(elapsed * 4))
                }
                .frame(width: 20, height: 20)

                // Stats + whimsy
                Text("GPU \(gpuPercent)%")
                    .foregroundStyle(gpuColor)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Mem \(memPercent)%")
                    .foregroundStyle(memColor)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(whimsy)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .onAppear {
            startDate = Date()
            pollMetrics()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                pollMetrics()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private var gpuColor: Color {
        if gpuPercent > 80 { return .orange }
        if gpuPercent > 50 { return .green }
        return .blue
    }

    private var memColor: Color {
        if memPercent > 85 { return .red }
        if memPercent > 70 { return .orange }
        return .secondary
    }

    private func pollMetrics() {
        gpuPercent = Int(SystemMetrics.gpuUtilization())
        memPercent = Int(SystemMetrics.memoryPressure())
        // Rotate whimsy every ~3 seconds
        if Int(Date().timeIntervalSince(startDate)) % 3 == 0 {
            withAnimation(.easeInOut(duration: 0.3)) {
                whimsy = Self.randomWhimsy()
            }
        }
    }

    private static let whimsies = [
        "marinating", "boondoggling", "razzle-dazzling", "percolating",
        "simmering", "noodling", "cogitating", "ruminating",
        "brainstorming", "daydreaming", "scheming", "concocting",
        "fermenting", "hatching", "brewing", "stewing",
        "tinkering", "finagling", "wrangling", "bamboozling",
        "gallivanting", "meandering", "pondering", "mulling",
        "churning", "synthesizing", "vibing", "manifesting",
        "jazz-handing", "shimmer-thinking", "pixel-wrangling",
        "quantum-leaping", "brain-tickling", "thought-juggling",
    ]

    private static func randomWhimsy() -> String {
        whimsies.randomElement() ?? "thinking"
    }
}

/// Reads macOS GPU utilization and memory pressure via IOKit/Mach (same APIs as status.zig).
enum SystemMetrics {

    /// GPU utilization percentage (0–100) via IOKit AGXAccelerator.
    static func gpuUtilization() -> UInt32 {
        var iter: io_iterator_t = 0
        guard let matching = IOServiceMatching("AGXAccelerator") else { return 0 }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iter) }

        let entry = IOIteratorNext(iter)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any],
              let perf = props["PerformanceStatistics"] as? [String: Any],
              let util = perf["Device Utilization %"] as? Int else { return 0 }
        return UInt32(min(max(util, 0), 100))
    }

    /// System memory pressure as percentage (0–100) via Mach host_statistics64.
    static func memoryPressure() -> UInt32 {
        var totalMem: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &totalMem, &len, nil, 0) == 0, totalMem > 0 else { return 0 }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return 0 }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<Int32>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * UInt64(pageSize)
        return UInt32(used * 100 / totalMem)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // Reasoning (collapsible)
                if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                    DisclosureGroup {
                        Text(reasoning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Thinking", systemImage: "brain")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Attached images
                if let images = message.images, !images.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(images) { img in
                            if let nsImage = NSImage(data: img.data) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 200, maxHeight: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }

                // Content
                if !message.content.isEmpty || message.isStreaming {
                    VStack(alignment: .leading, spacing: 4) {
                        if message.isAgentSummary {
                            Label("Tool Call", systemImage: "wrench.and.screwdriver")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        if message.role == .assistant {
                            MarkdownText(message.content.isEmpty && message.isStreaming ? " " : message.content)
                                .textSelection(.enabled)
                        } else {
                            Text(message.content)
                                .textSelection(.enabled)
                        }
                        if message.isStreaming {
                            GeneratingIndicator()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == .user ? Color.accentColor : Color(.controlBackgroundColor))
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                // Token usage stats
                if message.role == .assistant, !message.isStreaming,
                   let prompt = message.promptTokens, let completion = message.completionTokens {
                    HStack(spacing: 8) {
                        Text("\(prompt)+\(completion) tokens")
                        if let tps = message.tokensPerSecond, tps > 0 {
                            Text("~\(Int(tps)) tok/s")
                        }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                }
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            }
        }
    }
}

// MARK: - Markdown Rendering

struct MarkdownText: View {
    let source: String

    /// Tags emitted by models (thinking, planning, etc.) — rendered as XML blocks.
    /// Standard HTML tags (head, div, meta, etc.) are NOT included — they render as text.
    private static let modelTags: Set<String> = [
        "pad", "plan", "thinking", "thought", "reflection", "output",
        "step", "result", "answer", "reasoning", "tool_call", "tool_response",
    ]

    /// Tags whose content should be hidden from the chat entirely (consumed but
    /// not rendered). Real tool calls show in the dedicated tool-call UI; raw
    /// `<tool_call>` text in the assistant bubble is either a parser fallback or
    /// a malformed/truncated leak — neither is useful to display.
    private static let hiddenTags: Set<String> = [
        "tool_call", "tool_response",
    ]

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .contextMenu {
            Button("Copy All") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source, forType: .string)
            }
        }
    }

    private enum Block {
        case paragraph(String)
        case heading(Int, String)      // level, text
        case code(String, String)      // language, content
        case listItem(String)
        case xmlBlock(String)          // raw XML/tag content
    }

    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // XML-like tag block for model-specific tags (<plan>, <pad>, <thinking>, etc.)
            // Only match known model tags — NOT standard HTML tags like <head>, <div>, <meta>.
            if let match = line.range(of: "^<([a-zA-Z_]+)>", options: .regularExpression) {
                let tag = String(line[match]).dropFirst().dropLast() // extract tag name
                guard Self.modelTags.contains(String(tag)) else {
                    // Not a model tag — fall through to normal paragraph handling
                    i += 1
                    let text = line.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { blocks.append(.paragraph(text)) }
                    continue
                }
                let closeTag = "</\(tag)>"
                let isHidden = Self.hiddenTags.contains(String(tag))
                if line.contains(closeTag) {
                    // Single-line tag block
                    if !isHidden { blocks.append(.xmlBlock(line)) }
                    i += 1
                    continue
                }
                // Multi-line: collect until closing tag (or EOF for unclosed)
                var xmlLines: [String] = [line]
                i += 1
                while i < lines.count {
                    xmlLines.append(lines[i])
                    if lines[i].contains(closeTag) {
                        i += 1
                        break
                    }
                    i += 1
                }
                if !isHidden {
                    blocks.append(.xmlBlock(xmlLines.joined(separator: "\n")))
                }
                continue
            }

            // Standalone model tags like <pad><pad><pad>
            if line.hasPrefix("<") && line.contains(">") && !line.hasPrefix("<http") {
                let stripped = line.trimmingCharacters(in: .whitespaces)
                if stripped.range(of: "^(<[a-zA-Z_/]+>\\s*)+$", options: .regularExpression) != nil {
                    // Only treat as XML block if ALL tags are model tags
                    let tagNames = stripped.components(separatedBy: ">")
                        .compactMap { $0.components(separatedBy: "<").last?.replacingOccurrences(of: "/", with: "") }
                        .filter { !$0.isEmpty }
                    if tagNames.allSatisfy({ Self.modelTags.contains($0) }) {
                        blocks.append(.xmlBlock(stripped))
                        i += 1
                        continue
                    }
                }
            }

            // Fenced code block
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1 // skip closing ```
                blocks.append(.code(lang, code.joined(separator: "\n")))
                continue
            }

            // Heading
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6 {
                    let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty {
                        blocks.append(.heading(level, text))
                        i += 1
                        continue
                    }
                }
            }

            // List item
            if line.starts(with: "- ") || line.starts(with: "* ") ||
               (line.count >= 3 && line.first?.isNumber == true && line.contains(". ")) {
                let text: String
                if line.starts(with: "- ") || line.starts(with: "* ") {
                    text = String(line.dropFirst(2))
                } else if let dotIdx = line.firstIndex(of: "."), line[line.index(after: dotIdx)] == " " {
                    text = String(line[line.index(dotIdx, offsetBy: 2)...])
                } else {
                    text = line
                }
                blocks.append(.listItem(text))
                i += 1
                continue
            }

            // Empty line — skip
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph — collect consecutive non-empty lines
            var para: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                if next.trimmingCharacters(in: .whitespaces).isEmpty ||
                   next.hasPrefix("#") || next.hasPrefix("```") ||
                   next.starts(with: "- ") || next.starts(with: "* ") ||
                   next.hasPrefix("<") {
                    break
                }
                para.append(next)
                i += 1
            }
            blocks.append(.paragraph(para.joined(separator: "\n")))
        }

        return blocks
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            inlineMarkdown(text)

        case .heading(let level, let text):
            Text(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level == 1 ? 4 : 2)

        case .code(_, let content):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: NSColor(white: 0.08, alpha: 1)))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .listItem(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("\u{2022}")
                    .foregroundStyle(.secondary)
                inlineMarkdown(text)
            }

        case .xmlBlock(let content):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.purple.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    private func inlineMarkdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
