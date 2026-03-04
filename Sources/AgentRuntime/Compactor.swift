import Foundation
import Protocols

public struct CompactorRetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var initialBackoffNanoseconds: UInt64
    public var multiplier: Double
    public var maxBackoffNanoseconds: UInt64

    public init(
        maxAttempts: Int = 3,
        initialBackoffNanoseconds: UInt64 = 250_000_000,
        multiplier: Double = 2.0,
        maxBackoffNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialBackoffNanoseconds = initialBackoffNanoseconds
        self.multiplier = max(1.0, multiplier)
        self.maxBackoffNanoseconds = max(maxBackoffNanoseconds, initialBackoffNanoseconds)
    }

    public static let `default` = CompactorRetryPolicy()
}

public struct CompactionJobExecutionResult: Sendable, Equatable {
    public var success: Bool
    public var workerId: String?

    public init(success: Bool, workerId: String?) {
        self.success = success
        self.workerId = workerId
    }
}

private struct QueuedCompactionJob: Sendable {
    var job: CompactionJob
    var dedupKey: String
}

public actor Compactor {
    public typealias CompactionApplier = @Sendable (CompactionJob, WorkerRuntime) async -> CompactionJobExecutionResult
    public typealias SleepOperation = @Sendable (UInt64) async -> Void

    private let eventBus: EventBus
    private let retryPolicy: CompactorRetryPolicy
    private let applier: CompactionApplier
    private let sleepOperation: SleepOperation

    private var lastLevelByChannel: [String: CompactionLevel] = [:]
    private var queuedJobsByChannel: [String: [QueuedCompactionJob]] = [:]
    private var queuedJobKeysByChannel: [String: Set<String>] = [:]
    private var activeJobKeyByChannel: [String: String] = [:]
    private var drainingChannels: Set<String> = []

    public init(eventBus: EventBus) {
        self.eventBus = eventBus
        self.retryPolicy = .default
        self.applier = Compactor.defaultApplier
        self.sleepOperation = Compactor.defaultSleepOperation
    }

    public init(
        eventBus: EventBus,
        retryPolicy: CompactorRetryPolicy = .default,
        applier: @escaping CompactionApplier,
        sleepOperation: @escaping SleepOperation
    ) {
        self.eventBus = eventBus
        self.retryPolicy = retryPolicy
        self.applier = applier
        self.sleepOperation = sleepOperation
    }

    /// Evaluates channel context utilization and schedules compaction job when needed.
    public func evaluate(channelId: String, utilization: Double) async -> CompactionJob? {
        let level: CompactionLevel?
        let threshold: Double

        if utilization > 0.95 {
            level = .emergency
            threshold = 0.95
        } else if utilization > 0.85 {
            level = .aggressive
            threshold = 0.85
        } else if utilization > 0.80 {
            level = .soft
            threshold = 0.80
        } else {
            level = nil
            threshold = 0
        }

        guard let level else {
            lastLevelByChannel[channelId] = nil
            return nil
        }

        if lastLevelByChannel[channelId] == level {
            return nil
        }

        lastLevelByChannel[channelId] = level
        let job = CompactionJob(channelId: channelId, level: level, threshold: threshold)

        if let payload = try? JSONValueCoder.encode(job) {
            await eventBus.publish(
                EventEnvelope(
                    messageType: .compactorThresholdHit,
                    channelId: channelId,
                    payload: payload
                )
            )
        }

        return job
    }

    /// Enqueues compaction job and processes channel queue in background.
    public func apply(job: CompactionJob, workers: WorkerRuntime) async {
        let dedupKey = compactionDedupKey(for: job)

        if activeJobKeyByChannel[job.channelId] == dedupKey {
            return
        }

        var queuedKeys = queuedJobKeysByChannel[job.channelId, default: []]
        if queuedKeys.contains(dedupKey) {
            return
        }
        queuedKeys.insert(dedupKey)
        queuedJobKeysByChannel[job.channelId] = queuedKeys

        queuedJobsByChannel[job.channelId, default: []].append(
            QueuedCompactionJob(job: job, dedupKey: dedupKey)
        )
        scheduleQueueDrainIfNeeded(channelId: job.channelId, workers: workers)
    }

    private func scheduleQueueDrainIfNeeded(channelId: String, workers: WorkerRuntime) {
        let inserted = drainingChannels.insert(channelId).inserted
        guard inserted else {
            return
        }

        Task {
            await self.drainQueue(channelId: channelId, workers: workers)
        }
    }

    private func drainQueue(channelId: String, workers: WorkerRuntime) async {
        defer {
            drainingChannels.remove(channelId)
            cleanupQueueState(channelId: channelId)
            if hasPendingQueueWork(channelId: channelId) {
                scheduleQueueDrainIfNeeded(channelId: channelId, workers: workers)
            }
        }

        while let queuedJob = dequeueNext(channelId: channelId) {
            activeJobKeyByChannel[channelId] = queuedJob.dedupKey
            let result = await applyWithRetry(job: queuedJob.job, workers: workers)
            activeJobKeyByChannel[channelId] = nil

            if result.success {
                await publishSummaryApplied(job: queuedJob.job, workerId: result.workerId)
            }
        }
    }

    private func dequeueNext(channelId: String) -> QueuedCompactionJob? {
        guard var queue = queuedJobsByChannel[channelId], !queue.isEmpty else {
            return nil
        }

        let next = queue.removeFirst()
        if queue.isEmpty {
            queuedJobsByChannel[channelId] = nil
        } else {
            queuedJobsByChannel[channelId] = queue
        }

        var queuedKeys = queuedJobKeysByChannel[channelId] ?? []
        queuedKeys.remove(next.dedupKey)
        if queuedKeys.isEmpty {
            queuedJobKeysByChannel[channelId] = nil
        } else {
            queuedJobKeysByChannel[channelId] = queuedKeys
        }

        return next
    }

    private func applyWithRetry(job: CompactionJob, workers: WorkerRuntime) async -> CompactionJobExecutionResult {
        var attempt = 1
        var backoff = retryPolicy.initialBackoffNanoseconds

        while true {
            let result = await applier(job, workers)
            if result.success {
                return result
            }
            if attempt >= retryPolicy.maxAttempts {
                return result
            }

            await sleepOperation(backoff)
            backoff = nextBackoff(after: backoff)
            attempt += 1
        }
    }

    private func nextBackoff(after currentBackoff: UInt64) -> UInt64 {
        let next = Double(currentBackoff) * retryPolicy.multiplier
        let bounded = min(next, Double(retryPolicy.maxBackoffNanoseconds))
        return UInt64(bounded.rounded(.up))
    }

    private func publishSummaryApplied(job: CompactionJob, workerId: String?) async {
        await eventBus.publish(
            EventEnvelope(
                messageType: .compactorSummaryApplied,
                channelId: job.channelId,
                workerId: workerId,
                payload: .object([
                    "jobId": .string(job.id),
                    "level": .string(job.level.rawValue)
                ])
            )
        )
    }

    private func compactionDedupKey(for job: CompactionJob) -> String {
        "\(job.channelId):\(job.level.rawValue)"
    }

    private func hasPendingQueueWork(channelId: String) -> Bool {
        let queueHasEntries = !(queuedJobsByChannel[channelId] ?? []).isEmpty
        let hasActive = activeJobKeyByChannel[channelId] != nil
        return queueHasEntries || hasActive
    }

    private func cleanupQueueState(channelId: String) {
        if queuedJobsByChannel[channelId]?.isEmpty == true {
            queuedJobsByChannel[channelId] = nil
        }
        if queuedJobKeysByChannel[channelId]?.isEmpty == true {
            queuedJobKeysByChannel[channelId] = nil
        }
        if activeJobKeyByChannel[channelId] == nil {
            activeJobKeyByChannel.removeValue(forKey: channelId)
        }
    }

    private static func defaultApplier(job: CompactionJob, workers: WorkerRuntime) async -> CompactionJobExecutionResult {
        let spec = WorkerTaskSpec(
            taskId: "compaction-\(job.id)",
            channelId: job.channelId,
            title: "Compaction \(job.level.rawValue)",
            objective: "Summarize channel context at \(Int(job.threshold * 100))% threshold",
            tools: ["file"],
            mode: .fireAndForget
        )

        let workerId = await workers.spawn(spec: spec, autoStart: false)
        let artifact = await workers.completeNow(
            workerId: workerId,
            summary: "Compaction \(job.level.rawValue) summary applied"
        )
        return CompactionJobExecutionResult(success: artifact != nil, workerId: workerId)
    }

    private static func defaultSleepOperation(nanoseconds: UInt64) async {
        guard nanoseconds > 0 else {
            return
        }
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
