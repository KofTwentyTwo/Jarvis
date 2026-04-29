import Foundation
import JarvisChildSpawn
import Logging

/// Plan 07-05 / Task 4 — vllm-mlx sidecar lifecycle owner.
///
/// **Spawn invariants** (test-enforced; mirrors Phase 5 MCP helper pattern):
///   1. `ChildSpawnGate.shared.prepare()` runs BEFORE the Process is run.
///   2. `proc.environment = ChildSpawnGate.minimalEnvironment` verbatim
///      (`["PATH": "/usr/bin:/bin"]`). No parent env (HOME, USER, API keys)
///      leaks.
///   3. Process factory + spawn gate are injected so spawn config can be
///      captured by tests without actually running a vllm-mlx binary.
///
/// **Lifecycle**: lazy. `ensureRunning()` is the entry point — first T2 need
/// triggers `start()` with a bounded `/health` warmup window (default 60s).
/// Failure to reach /health within the window throws
/// `VisionError.sidecarStartupTimeout`; the caller transparently demotes to
/// T1 for the rest of the process lifetime (PATTERNS Risk #2 mitigation).
public actor VllmMlxSidecar {

    // MARK: - Public configuration

    public struct Configuration: Sendable {
        public let binaryURL: URL
        public let modelID: String
        public let port: Int
        public let healthTimeout: Duration
        public let healthProber: @Sendable (URL) async -> Bool

        public init(
            binaryURL: URL,
            modelID: String = "Qwen/Qwen3.5-35B-A3B-VL",
            port: Int = 8001,
            healthTimeout: Duration = .seconds(60),
            healthProber: @escaping @Sendable (URL) async -> Bool = Self.defaultHealthProber
        ) {
            self.binaryURL = binaryURL
            self.modelID = modelID
            self.port = port
            self.healthTimeout = healthTimeout
            self.healthProber = healthProber
        }

        /// Default /health probe — issues a GET and returns true on 2xx.
        @Sendable
        public static func defaultHealthProber(_ url: URL) async -> Bool {
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.0
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return true
                }
                return false
            } catch {
                return false
            }
        }
    }

    // MARK: - Injection seams (test-only fakes plug in here)

    /// Captured spawn configuration — what tests inspect after `start()` runs.
    public struct SpawnConfig: Sendable {
        public let binaryURL: URL
        public let arguments: [String]
        public let environment: [String: String]
    }

    /// Process abstraction. Real implementation wraps `Foundation.Process`;
    /// fake implementation captures the SpawnConfig for test inspection.
    public protocol ProcessHandle: Sendable {
        func run() throws
        func terminate()
        var isRunning: Bool { get }
    }

    /// Spawn-gate adapter — abstracted so tests can record the prepare()
    /// call ordering without sweeping real FDs.
    public protocol SpawnGate: Sendable {
        func prepare() async throws
    }

    public typealias ProcessFactory = @Sendable (SpawnConfig) async -> ProcessHandle

    // MARK: - Default real-process wiring

    public struct DefaultSpawnGateAdapter: SpawnGate {
        public init() {}
        public func prepare() async throws {
            try await ChildSpawnGate.shared.prepare()
        }
    }

    public final class DefaultProcessHandle: ProcessHandle, @unchecked Sendable {
        private let process: Process
        public init(spawnConfig: SpawnConfig) {
            let proc = Process()
            proc.executableURL = spawnConfig.binaryURL
            proc.arguments = spawnConfig.arguments
            proc.environment = spawnConfig.environment
            // Detach stdio — never inherit parent FDs (defense in depth on
            // top of ChildSpawnGate's FD_CLOEXEC sweep).
            proc.standardInput = nil
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            self.process = proc
        }
        public func run() throws { try process.run() }
        public func terminate() { process.terminate() }
        public var isRunning: Bool { process.isRunning }
    }

    public static let defaultProcessFactory: ProcessFactory = { config in
        DefaultProcessHandle(spawnConfig: config)
    }

    // MARK: - Stored state

    private let configuration: Configuration
    private let processFactory: ProcessFactory
    private let spawnGate: SpawnGate
    private let logger = Logger(label: "jarvis.vision.vllm-mlx-sidecar")

    private var handle: ProcessHandle?
    private var startupTask: Task<Void, Error>?

    public init(
        configuration: Configuration,
        processFactory: @escaping ProcessFactory = VllmMlxSidecar.defaultProcessFactory,
        spawnGate: SpawnGate = DefaultSpawnGateAdapter()
    ) {
        self.configuration = configuration
        self.processFactory = processFactory
        self.spawnGate = spawnGate
    }

    public var healthURL: URL {
        URL(string: "http://127.0.0.1:\(configuration.port)/health")!
    }

    // MARK: - Lifecycle

    /// Lazy entry point. First call invokes `start()`; subsequent calls return
    /// immediately if the handle is already running.
    public func ensureRunning() async throws {
        if let h = handle, h.isRunning { return }
        if let task = startupTask {
            try await task.value
            return
        }
        let task = Task { try await self.start() }
        startupTask = task
        do {
            try await task.value
        } catch {
            startupTask = nil
            throw error
        }
    }

    /// Start the sidecar and wait for /health to return 2xx within the
    /// configured timeout. Throws `VisionError.sidecarStartupTimeout` if the
    /// probe never succeeds.
    func start() async throws {
        // Invariant 1: ChildSpawnGate.prepare() BEFORE Process is created/run.
        try await spawnGate.prepare()

        // Invariant 2: minimalEnvironment verbatim. The process factory
        // captures this; real factory passes it to Process.environment.
        let spawnConfig = SpawnConfig(
            binaryURL: configuration.binaryURL,
            arguments: [
                "--model", configuration.modelID,
                "--port", String(configuration.port),
            ],
            environment: ChildSpawnGate.minimalEnvironment
        )

        let h = await processFactory(spawnConfig)
        self.handle = h

        do {
            try h.run()
        } catch {
            logger.error("vllm-mlx sidecar Process.run() threw: \(error)")
            throw VisionError.sidecarStartupTimeout
        }

        // Bounded /health warmup. Poll every 500ms up to healthTimeout.
        let probeURL = healthURL
        let deadline = ContinuousClock.now.advanced(by: configuration.healthTimeout)
        let prober = configuration.healthProber
        while ContinuousClock.now < deadline {
            if Task.isCancelled { throw CancellationError() }
            if await prober(probeURL) {
                logger.info("vllm-mlx sidecar /health responded; sidecar is ready")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        logger.warning("vllm-mlx sidecar /health timed out after \(configuration.healthTimeout)")
        throw VisionError.sidecarStartupTimeout
    }

    /// SIGTERM the running process, if any.
    public func shutdown() {
        handle?.terminate()
        handle = nil
        startupTask = nil
    }
}
