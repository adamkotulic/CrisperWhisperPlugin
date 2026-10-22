@preconcurrency import Foundation
import TypeWhisperPluginSDK

@objc(CrisperWhisperPlugin)
final class CrisperWhisperPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.adamkotulic.crisperwhisper"
    static let pluginName = "CrisperWhisper 2.0"

    let providerId = "crisperwhisper"
    let providerDisplayName = "CrisperWhisper 2.0 (Local)"
    let supportsTranslation = false
    let supportsStreaming = false

    private static let defaultSelectionId = "large-verbatim"
    private static let preferenceKey = "selectedModelId"

    private let stateLock = NSLock()
    private let serialGate = AsyncSerialGate()
    private var host: (any HostServices)?
    private var worker: CrisperWorker?
    private var pluginDataDirectory: URL?
    private var selectedSelectionId = defaultSelectionId

    required override init() {
        super.init()
    }

    var transcriptionModels: [PluginModelInfo] {
        ModelSelection.all.map {
            PluginModelInfo(
                id: $0.id,
                displayName: $0.displayName,
                sizeDescription: $0.sizeDescription,
                languageCount: supportedLanguages.count
            )
        }
    }

    var selectedModelId: String? {
        stateLock.withLock { selectedSelectionId }
    }

    var isConfigured: Bool {
        stateLock.withLock { worker?.isConfigured ?? false }
    }

    var supportedLanguages: [String] {
        Self.languageCodes
    }

    func activate(host: any HostServices) {
        let dataDirectory = host.pluginDataDirectory
        do {
            try FileManager.default.createDirectory(
                at: dataDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: dataDirectory.appendingPathComponent("TemporaryAudio", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            // A later transcription call reports a full, actionable error.
        }

        let saved = host.userDefault(forKey: Self.preferenceKey) as? String
        let validSaved = saved.flatMap(ModelSelection.init(id:))?.id
            ?? Self.defaultSelectionId
        if saved == nil {
            host.setUserDefault(validSaved, forKey: Self.preferenceKey)
        }

        let newWorker: CrisperWorker?
        if let scriptURL = Bundle(for: type(of: self)).url(
            forResource: "crisper_worker",
            withExtension: "py"
        ) {
            newWorker = CrisperWorker(
                pythonURL: Self.runtimeDirectory
                    .appendingPathComponent("venv/bin/python3", isDirectory: false),
                scriptURL: scriptURL,
                runtimeDirectory: Self.runtimeDirectory
            )
        } else {
            newWorker = nil
        }

        let oldWorker = stateLock.withLock { () -> CrisperWorker? in
            let old = worker
            self.host = host
            pluginDataDirectory = dataDirectory
            selectedSelectionId = validSaved
            worker = newWorker
            return old
        }
        oldWorker?.stop(reason: "Plugin reactivated")
        host.notifyCapabilitiesChanged()
    }

    func deactivate() {
        let oldWorker = stateLock.withLock { () -> CrisperWorker? in
            let old = worker
            worker = nil
            host = nil
            pluginDataDirectory = nil
            return old
        }
        oldWorker?.stop(reason: "Plugin deactivated")
    }

    func selectModel(_ modelId: String) {
        guard let selection = ModelSelection(id: modelId) else { return }
        let currentHost = stateLock.withLock { () -> (any HostServices)? in
            selectedSelectionId = selection.id
            return host
        }
        currentHost?.setUserDefault(selection.id, forKey: Self.preferenceKey)
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        if translate {
            throw CrisperPluginError.translationUnsupported
        }
        guard !audio.wavData.isEmpty else {
            throw CrisperPluginError.invalidAudio
        }

        let snapshot = stateLock.withLock {
            (
                selectionId: selectedSelectionId,
                worker: worker,
                dataDirectory: pluginDataDirectory
            )
        }

        guard let selection = ModelSelection(id: snapshot.selectionId) else {
            throw CrisperPluginError.invalidModel(snapshot.selectionId)
        }
        guard let worker = snapshot.worker,
              let dataDirectory = snapshot.dataDirectory else {
            throw CrisperPluginError.notActivated
        }
        guard worker.isConfigured else {
            throw CrisperPluginError.runtimeMissing(setupCommand: Self.setupCommand)
        }

        let normalizedLanguage = try Self.normalizeLanguage(language)
        let temporaryDirectory = dataDirectory
            .appendingPathComponent("TemporaryAudio", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        let audioURL = temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav", isDirectory: false)
        try audio.wavData.write(to: audioURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: audioURL.path
        )
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let timeout = min(max(600, audio.duration * 20 + 180), 3_600)
        let request = WorkerRequest(
            requestId: UUID().uuidString,
            command: "transcribe",
            audioPath: audioURL.path,
            model: selection.model,
            language: normalizedLanguage,
            mode: selection.mode,
            devicePolicy: "mps-preferred"
        )

        let response = try await serialGate.run {
            try await worker.request(request, timeout: timeout)
        }

        guard response.status == "success" else {
            throw CrisperPluginError.worker(
                response.message ?? "Unknown worker error"
            )
        }
        guard let text = response.text else {
            throw CrisperPluginError.worker("Worker returned no transcript text")
        }

        return PluginTranscriptionResult(
            text: text,
            detectedLanguage: response.language ?? normalizedLanguage
        )
    }

    private static var runtimeDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("TypeWhisper", isDirectory: true)
        .appendingPathComponent("CrisperWhisperRuntime", isDirectory: true)
    }

    private static var setupCommand: String {
        if let setupURL = Bundle(for: CrisperWhisperPlugin.self).url(
            forResource: "setup",
            withExtension: "sh"
        ) {
            return "/bin/bash \"\(setupURL.path)\" --model large"
        }
        return "Run the supplied setup.sh --model large"
    }

    private static func normalizeLanguage(_ rawLanguage: String?) throws -> String {
        guard let rawLanguage,
              !rawLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "auto"
        }

        let raw = rawLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if raw == "auto" {
            return "auto"
        }

        let base = raw
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? raw
        let aliases = ["cz": "cs", "iw": "he", "jp": "ja", "kr": "ko"]
        let normalized = aliases[base] ?? base
        guard languageCodes.contains(normalized) else {
            throw CrisperPluginError.unsupportedLanguage(rawLanguage)
        }
        return normalized
    }

    private static let languageCodes = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
        "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
        "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
        "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
        "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
        "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
        "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
        "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
        "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "zh"
    ]
}

private struct ModelSelection: Sendable {
    let id: String
    let model: String
    let mode: String
    let displayName: String
    let sizeDescription: String

    init?(id: String) {
        guard let found = Self.all.first(where: { $0.id == id }) else { return nil }
        self = found
    }

    private init(
        id: String,
        model: String,
        mode: String,
        displayName: String,
        sizeDescription: String
    ) {
        self.id = id
        self.model = model
        self.mode = mode
        self.displayName = displayName
        self.sizeDescription = sizeDescription
    }

    static let all: [ModelSelection] = [
        .init(id: "large-verbatim", model: "large", mode: "verbatim", displayName: "Large — Verbatim", sizeDescription: "2B parameters"),
        .init(id: "large-intended", model: "large", mode: "intended", displayName: "Large — Intended", sizeDescription: "2B parameters"),
        .init(id: "turbo-verbatim", model: "turbo", mode: "verbatim", displayName: "Turbo — Verbatim", sizeDescription: "Fastest"),
        .init(id: "turbo-intended", model: "turbo", mode: "intended", displayName: "Turbo — Intended", sizeDescription: "Fastest"),
        .init(id: "medium-verbatim", model: "medium", mode: "verbatim", displayName: "Medium — Verbatim", sizeDescription: "Balanced"),
        .init(id: "medium-intended", model: "medium", mode: "intended", displayName: "Medium — Intended", sizeDescription: "Balanced"),
        .init(id: "small-verbatim", model: "small", mode: "verbatim", displayName: "Small — Verbatim", sizeDescription: "Smallest"),
        .init(id: "small-intended", model: "small", mode: "intended", displayName: "Small — Intended", sizeDescription: "Smallest")
    ]
}

private struct WorkerRequest: Encodable, Sendable {
    let requestId: String
    let command: String
    let audioPath: String
    let model: String
    let language: String
    let mode: String
    let devicePolicy: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case command
        case audioPath = "audio_path"
        case model
        case language
        case mode
        case devicePolicy = "device_policy"
    }
}

private struct WorkerResponse: Decodable, Sendable {
    let requestId: String
    let status: String
    let text: String?
    let language: String?
    let mode: String?
    let model: String?
    let device: String?
    let computeType: String?
    let message: String?
    let errorType: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case status
        case text
        case language
        case mode
        case model
        case device
        case computeType = "compute_type"
        case message
        case errorType = "error_type"
    }
}

private final class RequestCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

private final class CrisperWorker: @unchecked Sendable {
    private struct PendingRequest {
        let id: String
        let continuation: CheckedContinuation<WorkerResponse, Error>
    }

    private let pythonURL: URL
    private let scriptURL: URL
    private let runtimeDirectory: URL
    private let stateLock = NSLock()

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var stderrTail = Data()
    private var pending: PendingRequest?

    init(pythonURL: URL, scriptURL: URL, runtimeDirectory: URL) {
        self.pythonURL = pythonURL
        self.scriptURL = scriptURL
        self.runtimeDirectory = runtimeDirectory
    }

    var isConfigured: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path)
            && FileManager.default.fileExists(atPath: scriptURL.path)
            && FileManager.default.fileExists(
                atPath: runtimeDirectory.appendingPathComponent("runtime-ready").path
            )
    }

    func request(_ request: WorkerRequest, timeout: TimeInterval) async throws -> WorkerResponse {
        let token = RequestCancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if token.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try beginRequest(request, continuation: continuation)
                    scheduleTimeout(requestId: request.requestId, after: timeout)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            token.cancel()
            self.cancel(requestId: request.requestId)
        }
    }

    func stop(reason: String) {
        terminate(reason: reason, cancellationError: CrisperPluginError.worker(reason))
    }

    private func beginRequest(
        _ request: WorkerRequest,
        continuation: CheckedContinuation<WorkerResponse, Error>
    ) throws {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)

        let input = try stateLock.withLock { () throws -> FileHandle in
            guard pending == nil else {
                throw CrisperPluginError.worker("Worker received overlapping requests")
            }
            try ensureProcessLocked()
            guard let inputHandle else {
                throw CrisperPluginError.worker("Worker stdin is unavailable")
            }
            pending = PendingRequest(id: request.requestId, continuation: continuation)
            return inputHandle
        }

        do {
            try input.write(contentsOf: data)
        } catch {
            complete(
                requestId: request.requestId,
                result: .failure(CrisperPluginError.worker("Could not write to Python worker: \(error.localizedDescription)")),
                stopProcess: true
            )
        }
    }

    private func ensureProcessLocked() throws {
        if let process, process.isRunning { return }

        // The previous process may have exited before its termination handler
        // ran; detach its pipes so stale EOF callbacks cannot touch the new one.
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputBuffer.removeAll(keepingCapacity: true)
        stderrTail.removeAll(keepingCapacity: true)

        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true
        )
        let cacheDirectory = runtimeDirectory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let newProcess = Process()
        newProcess.executableURL = pythonURL
        newProcess.arguments = ["-u", scriptURL.path]
        newProcess.currentDirectoryURL = runtimeDirectory
        newProcess.standardInput = stdinPipe
        newProcess.standardOutput = stdoutPipe
        newProcess.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        environment["HF_HOME"] = cacheDirectory.appendingPathComponent("huggingface", isDirectory: true).path
        environment["TORCH_HOME"] = cacheDirectory.appendingPathComponent("torch", isDirectory: true).path
        environment["CRISPERWHISPER_LOG_FILE"] = runtimeDirectory.appendingPathComponent("worker.log").path
        newProcess.environment = environment

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        // At EOF a readability handler keeps firing with empty data until it is
        // removed, so each handler detaches itself once its pipe closes.
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.handleEndOfFile(from: handle)
            } else {
                self?.handleStdout(data, from: handle)
            }
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.handleStderr(data, from: handle)
            }
        }
        newProcess.terminationHandler = { [weak self] terminated in
            self?.handleTermination(of: terminated)
        }

        do {
            try newProcess.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw CrisperPluginError.worker(
                "Could not launch Python at \(pythonURL.path): \(error.localizedDescription)"
            )
        }

        process = newProcess
        inputHandle = stdinPipe.fileHandleForWriting
        outputHandle = stdoutHandle
        errorHandle = stderrHandle
    }

    private func handleStdout(_ data: Data, from handle: FileHandle) {
        var completeLines: [Data] = []
        stateLock.withLock {
            guard outputHandle === handle else { return }
            outputBuffer.append(data)
            while let newline = outputBuffer.firstIndex(of: 0x0A) {
                completeLines.append(Data(outputBuffer[..<newline]))
                outputBuffer.removeSubrange(...newline)
            }
        }

        for line in completeLines where !line.isEmpty {
            do {
                let response = try JSONDecoder().decode(WorkerResponse.self, from: line)
                let delivered = complete(
                    requestId: response.requestId,
                    result: .success(response),
                    stopProcess: false
                )
                if !delivered, response.status != "success" {
                    // Errors that carry no matching request id (e.g. the worker's
                    // startup failure) must fail the pending request instead of
                    // leaving it to hang until its timeout.
                    terminate(
                        reason: "Worker reported an unroutable error",
                        cancellationError: CrisperPluginError.worker(
                            response.message ?? "Python worker reported an error before accepting requests"
                        )
                    )
                }
            } catch {
                let raw = String(data: line, encoding: .utf8) ?? "<non-UTF8>"
                terminate(
                    reason: "Invalid JSON from Python worker: \(raw)",
                    cancellationError: CrisperPluginError.worker("Invalid worker response: \(error.localizedDescription)")
                )
            }
        }
    }

    private func handleStderr(_ data: Data, from handle: FileHandle) {
        let maximumTailBytes = 32_768
        stateLock.withLock {
            guard errorHandle === handle else { return }
            stderrTail.append(data)
            if stderrTail.count > maximumTailBytes {
                stderrTail.removeFirst(stderrTail.count - maximumTailBytes)
            }
        }
    }

    private func handleEndOfFile(from handle: FileHandle) {
        let shouldTerminate = stateLock.withLock { outputHandle === handle && pending != nil }
        if shouldTerminate {
            terminate(
                reason: "Python worker closed stdout",
                cancellationError: CrisperPluginError.worker("Python worker closed unexpectedly")
            )
        }
    }

    private func handleTermination(of terminatedProcess: Process) {
        let details = stateLock.withLock { () -> (PendingRequest?, String)? in
            guard process === terminatedProcess else { return nil }
            let pendingRequest = pending
            pending = nil
            process = nil
            inputHandle = nil
            outputHandle?.readabilityHandler = nil
            errorHandle?.readabilityHandler = nil
            outputHandle = nil
            errorHandle = nil
            let diagnostics = String(data: stderrTail, encoding: .utf8) ?? ""
            return (pendingRequest, diagnostics)
        }

        guard let details, let pendingRequest = details.0 else { return }
        let suffix = details.1.isEmpty ? "" : "\n\nWorker diagnostics:\n\(details.1)"
        pendingRequest.continuation.resume(
            throwing: CrisperPluginError.worker(
                "Python worker exited with status \(terminatedProcess.terminationStatus).\(suffix)"
            )
        )
    }

    private func scheduleTimeout(requestId: String, after timeout: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            let stillPending = self.stateLock.withLock { self.pending?.id == requestId }
            if stillPending {
                self.terminate(
                    reason: "Transcription timed out after \(Int(timeout)) seconds",
                    cancellationError: CrisperPluginError.worker("Transcription timed out after \(Int(timeout)) seconds")
                )
            }
        }
    }

    private func cancel(requestId: String) {
        let matches = stateLock.withLock { pending?.id == requestId }
        if matches {
            terminate(reason: "Transcription cancelled", cancellationError: CancellationError())
        }
    }

    @discardableResult
    private func complete(
        requestId: String,
        result: Result<WorkerResponse, Error>,
        stopProcess: Bool
    ) -> Bool {
        let pendingRequest = stateLock.withLock { () -> PendingRequest? in
            guard pending?.id == requestId else { return nil }
            let current = pending
            pending = nil
            return current
        }
        pendingRequest?.continuation.resume(with: result)
        if stopProcess {
            terminate(reason: "Worker I/O failure", cancellationError: nil)
        }
        return pendingRequest != nil
    }

    private func terminate(reason: String, cancellationError: Error?) {
        let state = stateLock.withLock { () -> (Process?, PendingRequest?, String) in
            let runningProcess = process
            let pendingRequest = pending
            let diagnostics = String(data: stderrTail, encoding: .utf8) ?? ""
            pending = nil
            process = nil
            inputHandle = nil
            outputHandle?.readabilityHandler = nil
            errorHandle?.readabilityHandler = nil
            outputHandle = nil
            errorHandle = nil
            outputBuffer.removeAll(keepingCapacity: true)
            return (runningProcess, pendingRequest, diagnostics)
        }

        if let runningProcess = state.0, runningProcess.isRunning {
            runningProcess.terminationHandler = nil
            runningProcess.terminate()
        }

        if let pendingRequest = state.1, let cancellationError {
            let suffix = state.2.isEmpty ? "" : "\n\nWorker diagnostics:\n\(state.2)"
            if cancellationError is CancellationError {
                pendingRequest.continuation.resume(throwing: cancellationError)
            } else {
                pendingRequest.continuation.resume(
                    throwing: CrisperPluginError.worker("\(reason)\(suffix)")
                )
            }
        }
    }
}

private actor AsyncSerialGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var occupied = false
    private var waiters: [Waiter] = []

    func run<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !occupied {
            occupied = true
            return
        }
        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: waiterId, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterId) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume()
        } else {
            occupied = false
        }
    }
}

private enum CrisperPluginError: LocalizedError, Sendable {
    case notActivated
    case runtimeMissing(setupCommand: String)
    case translationUnsupported
    case unsupportedLanguage(String)
    case invalidAudio
    case invalidModel(String)
    case worker(String)

    var errorDescription: String? {
        switch self {
        case .notActivated:
            return "CrisperWhisper plugin has not been activated by TypeWhisper."
        case .runtimeMissing(let setupCommand):
            return "CrisperWhisper runtime is not installed. Run in Terminal:\n\(setupCommand)"
        case .translationUnsupported:
            return "CrisperWhisper transcription does not support translation in this plugin."
        case .unsupportedLanguage(let language):
            return "Unsupported language code: \(language)"
        case .invalidAudio:
            return "TypeWhisper supplied an empty audio recording."
        case .invalidModel(let model):
            return "Invalid CrisperWhisper model selection: \(model)"
        case .worker(let message):
            return message
        }
    }
}
