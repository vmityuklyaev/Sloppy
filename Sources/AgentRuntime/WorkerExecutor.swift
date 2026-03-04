import Foundation
import Protocols

public enum WorkerExecutionResult: Sendable, Equatable {
    case completed(summary: String)
    case waitingForRoute(report: String?)
}

public enum WorkerRouteExecutionResult: Sendable, Equatable {
    case waitingForRoute(report: String?)
    case completed(summary: String)
    case failed(error: String)
}

public protocol WorkerExecutor: Sendable {
    func execute(workerId: String, spec: WorkerTaskSpec) async throws -> WorkerExecutionResult
    func route(workerId: String, spec: WorkerTaskSpec, message: String) async throws -> WorkerRouteExecutionResult
    func cancel(workerId: String, spec: WorkerTaskSpec) async
}

public struct DefaultWorkerExecutor: WorkerExecutor {
    public init() {}

    public func execute(workerId: String, spec: WorkerTaskSpec) async throws -> WorkerExecutionResult {
        switch spec.mode {
        case .fireAndForget:
            if let summary = executeCreateFileObjective(spec: spec) {
                return .completed(summary: summary)
            }
            return .completed(summary: "Completed objective: \(spec.objective)")

        case .interactive:
            return .waitingForRoute(report: "waiting_for_route")
        }
    }

    public func route(workerId: String, spec: WorkerTaskSpec, message: String) async throws -> WorkerRouteExecutionResult {
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedMessage == "fail" || normalizedMessage == "ошибка" {
            return .failed(error: "Interactive worker marked as failed by route command")
        }

        if normalizedMessage.contains("done") || normalizedMessage.contains("готово") {
            return .completed(summary: "Interactive worker completed after route command")
        }

        return .waitingForRoute(report: nil)
    }

    public func cancel(workerId: String, spec: WorkerTaskSpec) async {}

    private func executeCreateFileObjective(spec: WorkerTaskSpec) -> String? {
        let objective = spec.objective
        guard let text = extractFileText(from: objective),
              let artifactsDirectory = extractArtifactsDirectory(from: objective)
        else {
            return nil
        }

        let filename = extractRequestedFilename(from: objective) ?? "artifact-\(UUID().uuidString.prefix(8)).txt"
        let sanitizedFilename = sanitizeFilename(String(filename))
        let directoryURL = URL(fileURLWithPath: artifactsDirectory, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent(sanitizedFilename)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return "Created file at \(fileURL.path)\nContent preview: \(String(text.prefix(200)))"
        } catch {
            return "Completed objective: \(objective)\nFile write failed at \(fileURL.path): \(error.localizedDescription)"
        }
    }

    private func extractArtifactsDirectory(from objective: String) -> String? {
        if let value = captureGroup(
            source: objective,
            pattern: #"(?im)^-\s*Store all created files and artifacts under:\s*(.+?)\s*$"#
        ) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let fallback = captureGroup(source: objective, pattern: #"(/[^ \n\t]+/artifacts)\b"#) {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func extractFileText(from objective: String) -> String? {
        let patterns = [
            #"(?is)create\s+file(?:\s+named\s+[A-Za-z0-9._-]+)?\s+with\s+text\s*["“](.+?)["”]"#,
            #"(?is)create\s+file\s*["“](.+?)["”]"#,
            #"(?is)создай(?:те)?\s+файл(?:\s+с\s+именем\s+[A-Za-z0-9._-]+)?\s+с\s+текстом\s*["«](.+?)["»]"#
        ]
        for pattern in patterns {
            if let value = captureGroup(source: objective, pattern: pattern) {
                return value
            }
        }
        return nil
    }

    private func extractRequestedFilename(from objective: String) -> String? {
        let patterns = [
            #"(?is)create\s+file\s+named\s+([A-Za-z0-9._-]+)"#,
            #"(?is)создай(?:те)?\s+файл\s+с\s+именем\s+([A-Za-z0-9._-]+)"#
        ]
        for pattern in patterns {
            if let value = captureGroup(source: objective, pattern: pattern) {
                return value
            }
        }
        return nil
    }

    private func sanitizeFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let sanitizedScalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(sanitizedScalars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if sanitized.isEmpty {
            return "artifact-\(UUID().uuidString.prefix(8)).txt"
        }
        return sanitized
    }

    private func captureGroup(source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsSource = source as NSString
        let range = NSRange(location: 0, length: nsSource.length)
        guard let match = regex.firstMatch(in: source, options: [], range: range),
              match.numberOfRanges > 1
        else {
            return nil
        }
        let groupRange = match.range(at: 1)
        guard groupRange.location != NSNotFound else {
            return nil
        }
        return nsSource.substring(with: groupRange)
    }
}
