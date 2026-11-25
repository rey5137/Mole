import Foundation

public struct RunResult {
    public var stdout = Data()
    public var stderrLines: [String] = []
    public var exitCode: Int32 = 0
    public var cancelled = false
    public var launchError: String?
    public var timedOut = false
    public var spawnedAt: Date?
    public var exitedAt: Date?
    public var stderrTail: String { stderrLines.suffix(8).joined(separator: "\n") }
}

private final class Locked<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// Runs one `mo` command in its own process group: stdin /dev/null, no
/// colour, stdout kept apart from stderr (streamed line by line). `cancel()`
/// sends SIGINT to the whole group, then SIGTERM after `termGraceSeconds` and
/// SIGKILL 1.5 s later to anything still alive, so Mole's children stop too.
public final class MoleRunner {
    public let executable: String
    public var termGraceSeconds: Double = 5
    private let state = Locked((pid: pid_t(0), cancelled: false, finished: false))

    public init(executable: String) { self.executable = executable }

    /// `only` limits the signal to that run: a timeout armed by an earlier run of this
    /// runner (the `--version` check before a scan) must not reach a later run.
    private func signalGroup(_ sig: Int32, only: pid_t? = nil) -> Bool {
        state.with { st in
            guard st.pid > 0, !st.finished else { return false }
            if let only, st.pid != only { return false }
            return killpg(st.pid, sig) == 0
        }
    }

    public var isCancelled: Bool { state.with { $0.cancelled } }

    /// Sticky: a cancel before the process exists (or between two runs of this
    /// runner) still makes the next `run` return `cancelled` without spawning.
    public func cancel() {
        let running = state.with { st -> Bool in
            st.cancelled = true
            return st.pid > 0 && !st.finished
        }
        guard running else { return }
        _ = signalGroup(SIGINT)
        let grace = termGraceSeconds
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            if signalGroup(SIGTERM) {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [self] in _ = signalGroup(SIGKILL) }
            }
        }
    }

    /// Blocks until the command ends. Call from a background thread.
    /// `timeout` stops a run that has not ended by then (SIGTERM to the group,
    /// SIGKILL 1.5 s later) and sets `timedOut`.
    public func run(arguments: [String], extraEnvironment: [String: String] = [:], timeout: TimeInterval? = nil,
                    onStderrLine: ((String) -> Void)? = nil) -> RunResult {
        if state.with({ $0.cancelled }) {
            var r = RunResult()
            r.cancelled = true
            r.exitCode = 130
            return r
        }
        state.with { $0.pid = 0; $0.finished = false }
        var env = ProcessInfo.processInfo.environment
        env["MOLE_NO_COLOR"] = "1"
        env["NO_COLOR"] = "1"
        for (k, v) in extraEnvironment { env[k] = v }
        var result = RunResult()

        let outPipe = Pipe(), errPipe = Pipe()
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&fa, errPipe.fileHandleForWriting.fileDescriptor, 2)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr) }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fa, &attr, argv, envp)
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        guard rc == 0 else {
            result.launchError = "Cannot run \(executable): \(String(cString: strerror(rc)))"
            result.exitCode = 127
            return result
        }
        let timedOutFlag = Locked(false)
        state.with { $0.pid = pid }
        result.spawnedAt = Date()
        if let t = timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + t) { [self] in
                if signalGroup(SIGTERM, only: pid) {
                    timedOutFlag.with { $0 = true }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [self] in _ = signalGroup(SIGKILL, only: pid) }
                }
            }
        }

        let out = Locked(Data())
        let lines = Locked([String]())
        let partial = Locked(Data())
        let group = DispatchGroup()

        func emit(_ line: String) {
            lines.with { $0.append(line) }
            onStderrLine?(line)
        }
        group.enter()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; group.leave(); return }
            out.with { $0.append(d) }
        }
        group.enter()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                let rest = partial.with { p -> Data in let r = p; p = Data(); return r }
                if !rest.isEmpty { emit(String(decoding: rest, as: UTF8.self)) }
                group.leave()
                return
            }
            var complete: [Data] = []
            partial.with { p in
                p.append(d)
                while let nl = p.firstIndex(of: 0x0A) {
                    complete.append(p.subdata(in: p.startIndex..<nl))
                    p.removeSubrange(p.startIndex...nl)
                }
            }
            for l in complete { emit(String(decoding: l, as: UTF8.self)) }
        }

        // Wait for the leader without reaping it: while it is a zombie its pid, and so
        // the process-group id, stays reserved, and no late signal can reach a reused id.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
        result.exitedAt = Date()
        // After a cancel or timeout, give the group's other members (which hold the
        // pipes) time to go; the signal escalation keeps running meanwhile.
        if state.with({ $0.cancelled }) || timedOutFlag.with({ $0 }) {
            _ = group.wait(timeout: .now() + termGraceSeconds + 3)
        }
        state.with { $0.finished = true }   // from here no signal is sent
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        // A grandchild that kept a pipe open must not hang the app.
        if group.wait(timeout: .now() + 2) == .timedOut {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }
        result.stdout = out.with { $0 }
        result.stderrLines = lines.with { $0 }
        let wasSignalled = (status & 0x7f) != 0
        result.exitCode = wasSignalled ? 128 + (status & 0x7f) : (status >> 8) & 0xff
        result.cancelled = state.with { $0.cancelled }
        result.timedOut = timedOutFlag.with { $0 }
        return result
    }
}
