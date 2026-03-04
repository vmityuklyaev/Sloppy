import Foundation
import Testing
@testable import AgentRuntime
@testable import PluginSDK
@testable import Protocols

@Test
func routingDecisionForWorkerIntent() async {
    let system = RuntimeSystem()

    let decision = await system.postMessage(
        channelId: "general",
        request: ChannelMessageRequest(userId: "u1", content: "please implement and run tests")
    )

    #expect(decision.action == .spawnWorker)
}

@Test
func interactiveWorkerRouteCompletion() async {
    let system = RuntimeSystem()
    let spec = WorkerTaskSpec(
        taskId: "task-route",
        channelId: "general",
        title: "Interactive",
        objective: "wait for route",
        tools: ["shell"],
        mode: .interactive
    )

    let workerId = await system.createWorker(spec: spec)
    let accepted = await system.routeMessage(channelId: "general", workerId: workerId, message: "done")
    #expect(accepted)
}

@Test
func compactorThresholdsProduceEvents() async {
    let bus = EventBus()
    let compactor = Compactor(eventBus: bus)

    let job1 = await compactor.evaluate(channelId: "c1", utilization: 0.81)
    #expect(job1?.level == .soft)

    let job2 = await compactor.evaluate(channelId: "c1", utilization: 0.90)
    #expect(job2?.level == .aggressive)

    let job3 = await compactor.evaluate(channelId: "c1", utilization: 0.97)
    #expect(job3?.level == .emergency)
}

@Test
func compactorDeduplicatesInFlightJobsByChannelAndLevel() async {
    let bus = EventBus()
    let workers = WorkerRuntime(eventBus: bus)
    let applier = BlockingCompactionApplier()
    let compactor = Compactor(
        eventBus: bus,
        applier: { job, _ in
            await applier.execute(job: job)
        },
        sleepOperation: { _ in }
    )

    let job = CompactionJob(channelId: "c1", level: .aggressive, threshold: 0.85)
    await compactor.apply(job: job, workers: workers)
    await applier.waitUntilFirstAttemptIsBlocked()

    await compactor.apply(job: job, workers: workers)
    await applier.releaseFirstAttempt()

    let summaryEvent = await firstEvent(
        matching: .compactorSummaryApplied,
        in: await bus.subscribe()
    )

    #expect(summaryEvent != nil)
    #expect(await applier.attempts(for: .aggressive) == 1)
}

@Test
func compactorRetriesWithBackoffUntilSuccess() async {
    let bus = EventBus()
    let workers = WorkerRuntime(eventBus: bus)
    let applier = FlakyCompactionApplier(failuresBeforeSuccess: 2)
    let sleepRecorder = SleepRecorder()
    let retryPolicy = CompactorRetryPolicy(
        maxAttempts: 3,
        initialBackoffNanoseconds: 10_000,
        multiplier: 2.0,
        maxBackoffNanoseconds: 20_000
    )
    let compactor = Compactor(
        eventBus: bus,
        retryPolicy: retryPolicy,
        applier: { job, _ in
            await applier.execute(job: job)
        },
        sleepOperation: { duration in
            await sleepRecorder.record(duration)
        }
    )

    await compactor.apply(
        job: CompactionJob(channelId: "c1", level: .emergency, threshold: 0.95),
        workers: workers
    )

    let summaryEvent = await firstEvent(
        matching: .compactorSummaryApplied,
        in: await bus.subscribe()
    )

    #expect(summaryEvent != nil)
    #expect(await applier.attemptCount() == 3)
    #expect(await sleepRecorder.values() == [10_000, 20_000])
}

@Test
func branchIsEphemeralAfterConclusion() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let branchRuntime = BranchRuntime(eventBus: bus, memoryStore: memory)

    let branchId = await branchRuntime.spawn(channelId: "general", prompt: "research topic")
    let countBefore = await branchRuntime.activeBranchesCount()
    #expect(countBefore == 1)

    _ = await branchRuntime.conclude(
        branchId: branchId,
        summary: "final summary",
        artifactRefs: [],
        tokenUsage: TokenUsage(prompt: 20, completion: 10)
    )

    let countAfter = await branchRuntime.activeBranchesCount()
    #expect(countAfter == 0)
}

@Test
func visorCreatesBulletin() async {
    let bus = EventBus()
    let memory = InMemoryMemoryStore()
    let visor = Visor(eventBus: bus, memoryStore: memory)

    let bulletin = await visor.generateBulletin(channels: [], workers: [])
    #expect(!bulletin.digest.isEmpty)

    let entries = await memory.entries()
    #expect(entries.count == 1)
}

private actor ToolInvocationCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor SequencedModelProvider: ModelProviderPlugin {
    let id: String = "sequenced"
    let models: [String] = ["mock-model"]
    private var queue: [String]

    init(outputs: [String]) {
        self.queue = outputs
    }

    func complete(model: String, prompt: String, maxTokens: Int) async throws -> String {
        if queue.isEmpty {
            return "No output."
        }
        return queue.removeFirst()
    }
}

private actor PromptCapturingModelProvider: ModelProviderPlugin {
    let id: String = "prompt-capturing"
    let models: [String] = ["mock-model"]
    private(set) var prompts: [String] = []

    func complete(model: String, prompt: String, maxTokens: Int) async throws -> String {
        prompts.append(prompt)
        return "Captured."
    }

    func lastPrompt() -> String? {
        prompts.last
    }
}

@Test
func respondInlineAutoToolCallingLoop() async {
    let provider = SequencedModelProvider(
        outputs: [
            "{\"tool\":\"agents.list\",\"arguments\":{},\"reason\":\"need agents\"}",
            "Final answer after tool execution."
        ]
    )
    let invocationCounter = ToolInvocationCounter()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")

    let decision = await system.postMessage(
        channelId: "tool-loop",
        request: ChannelMessageRequest(userId: "u1", content: "hello"),
        toolInvoker: { request in
            await invocationCounter.increment()
            #expect(request.tool == "agents.list")
            return ToolInvocationResult(
                tool: request.tool,
                ok: true,
                data: .array([])
            )
        }
    )

    #expect(decision.action == .respond)
    let snapshot = await system.channelState(channelId: "tool-loop")
    let finalMessage = snapshot?.messages.last(where: { $0.userId == "system" })?.content ?? ""
    #expect(finalMessage == "Final answer after tool execution.")
    #expect(await invocationCounter.value() == 1)
}

@Test
func respondInlineIncludesBootstrapContextInPrompt() async {
    let provider = PromptCapturingModelProvider()
    let system = RuntimeSystem(modelProvider: provider, defaultModel: "mock-model")
    let channelId = "session-bootstrap"

    await system.appendSystemMessage(
        channelId: channelId,
        content: """
        [agent_session_context_bootstrap_v1]
        [Identity.md]
        Тебя зовут Серега
        """
    )

    _ = await system.postMessage(
        channelId: channelId,
        request: ChannelMessageRequest(userId: "dashboard", content: "привет, как тебя зовут?")
    )

    let prompt = await provider.lastPrompt() ?? ""
    #expect(prompt.contains("[agent_session_context_bootstrap_v1]"))
    #expect(prompt.contains("Тебя зовут Серега"))
    #expect(prompt.contains("привет, как тебя зовут?"))
}

private actor BlockingCompactionApplier {
    private var attemptsByLevel: [String: Int] = [:]
    private var isFirstAttemptBlocked = false
    private var firstAttemptReadyContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func execute(job: CompactionJob) async -> CompactionJobExecutionResult {
        attemptsByLevel[job.level.rawValue, default: 0] += 1

        if !isFirstAttemptBlocked {
            isFirstAttemptBlocked = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                firstAttemptReadyContinuation?.resume()
                firstAttemptReadyContinuation = nil
            }
        }

        return CompactionJobExecutionResult(success: true, workerId: "compaction-worker-blocking")
    }

    func waitUntilFirstAttemptIsBlocked() async {
        if isFirstAttemptBlocked, releaseContinuation != nil {
            return
        }

        await withCheckedContinuation { continuation in
            firstAttemptReadyContinuation = continuation
        }
    }

    func releaseFirstAttempt() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func attempts(for level: CompactionLevel) -> Int {
        attemptsByLevel[level.rawValue, default: 0]
    }
}

private actor FlakyCompactionApplier {
    private var failuresBeforeSuccess: Int
    private var attempts = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func execute(job _: CompactionJob) -> CompactionJobExecutionResult {
        attempts += 1
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            return CompactionJobExecutionResult(success: false, workerId: "compaction-worker-flaky")
        }

        return CompactionJobExecutionResult(success: true, workerId: "compaction-worker-flaky")
    }

    func attemptCount() -> Int {
        attempts
    }
}

private actor SleepRecorder {
    private var recorded: [UInt64] = []

    func record(_ nanoseconds: UInt64) {
        recorded.append(nanoseconds)
    }

    func values() -> [UInt64] {
        recorded
    }
}

private func firstEvent(
    matching type: MessageType,
    in stream: AsyncStream<EventEnvelope>,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async -> EventEnvelope? {
    await withTaskGroup(of: EventEnvelope?.self) { group in
        group.addTask {
            for await event in stream {
                if event.messageType == type {
                    return event
                }
            }
            return nil
        }

        group.addTask {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            return nil
        }

        let event = await group.next() ?? nil
        group.cancelAll()
        return event
    }
}
