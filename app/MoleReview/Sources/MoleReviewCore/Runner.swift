import Foundation

public struct RunResult {
    public var stdout = Data()
    public var stderrLines: [String] = []
    /// Every complete line of stdout, in order (also kept whole in `stdout`).
    public var stdoutLines: [String] = []
    public var exitCode: Int32 = 0
    public var cancelled = false
    public var launchError: String?
    public var timedOut = false
    public init() {}
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

extension MoleRunner {
    /// A pipe holding `secret` and a newline, write end already closed; returns the read
    /// end, close-on-exec and numbered 10 or higher so it is never `passwordFD` itself.
    static func secretPipe(_ secret: AdminPassword) -> Int32? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        let readFD = fcntl(fds[0], F_DUPFD_CLOEXEC, 10)
        close(fds[0])
        // Nothing is written unless the child's end exists.
        guard readFD >= 0 else { close(fds[1]); return nil }
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        // A failed write returns EPIPE instead of killing the app with SIGPIPE.
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
        func writeAll(_ p: UnsafeRawPointer, _ n: Int) -> Bool {
            var off = 0
            while off < n {
                let w = write(fds[1], p + off, n - off)
                if w < 0 { if errno == EINTR { continue }; return false }
                off += w
            }
            return true
        }
        let wrote = secret.withBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            var nl: UInt8 = 0x0A
            return writeAll(base, buf.count) && writeAll(&nl, 1)
        } ?? false
        close(fds[1])
        guard wrote else { close(readFD); return nil }
        return readFD
    }
}

/// Cuts a byte stream into lines. A `\r` rewrite (a spinner redrawing its line)
/// keeps only the text after the last one.
public final class LineSplitter {
    private var buffer = Data()
    public init() {}
    /// Reads along the buffer and drops the consumed front once per call, not once per line.
    public func feed(_ d: Data) -> [String] {
        buffer.append(d)
        var out: [String] = []
        var pos = buffer.startIndex
        while let nl = buffer[pos...].firstIndex(of: 0x0A) {
            out.append(LineSplitter.decode(buffer[pos..<nl]))
            pos = nl + 1
        }
        if pos > buffer.startIndex { buffer = Data(buffer[pos...]) }
        return out
    }
    public func finish() -> String? {
        defer { buffer = Data() }
        return buffer.isEmpty ? nil : LineSplitter.decode(buffer)
    }
    private static func decode(_ d: Data) -> String {
        var d = d
        while d.last == 0x0D { d.removeLast() }
        if let cr = d.lastIndex(of: 0x0D) { d = d.subdata(in: d.index(after: cr)..<d.endIndex) }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Runs one `mo` command in its own process group: stdin /dev/null, no
/// colour, stdout kept apart from stderr (both streamed line by line). `cancel()`
/// sends SIGINT to the whole group, then SIGTERM after `termGraceSeconds` and
/// SIGKILL 1.5 s later to anything still alive, so Mole's children stop too.
public final class MoleRunner {
    public let executable: String
    public var termGraceSeconds: Double = 5
    /// The fd a run's admin password arrives on in `mo` (`MOLE_SUDO_PASSWORD_FD`, lib/core/sudo.sh).
    /// 3, 4, 7 and 9 are taken by Mole's own redirections.
    public static let passwordFD: Int32 = 5
    private let state = Locked((pid: pid_t(0), cancelled: false, finished: false, inRun: false))

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
        escalate()
    }

    /// True from the moment `run` starts until it returns.
    public var isRunning: Bool { state.with { $0.inRun } }

    /// Blocks until none of `runners` is inside `run`, or `timeout` passes; false on timeout.
    public static func waitUntilStopped(_ runners: [MoleRunner], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while runners.contains(where: { $0.isRunning }) {
            if Date() >= deadline { return false }
            usleep(50_000)
        }
        return true
    }

    /// SIGTERM to the whole group now, for the app's last moment (`applicationWillTerminate`).
    public func terminateNow() {
        state.with { $0.cancelled = true }
        _ = signalGroup(SIGTERM)
    }

    private func escalate() {
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
    /// `onStdoutLine` is for runs whose stdout is progress text (`--apply`); a scan keeps its
    /// stdout for the JSON document and passes none. Stdout is cut into lines only when
    /// `onStdoutLine` is set or `collectStdoutLines` asks for `stdoutLines`: a plan's JSON is
    /// many MB and nothing reads it by line. Both callbacks run on reader threads.
    /// `secret`: the admin password, written once to a pipe whose read end the child gets on
    /// `passwordFD` (named in `MOLE_SUDO_PASSWORD_FD`); the write end is closed before the
    /// child starts and the read end right after, in this process. Without one, the variable
    /// is removed from the child's environment. The secret never enters argv or the environment.
    public func run(arguments: [String], extraEnvironment: [String: String] = [:], timeout: TimeInterval? = nil,
                    onStderrLine: ((String) -> Void)? = nil, onStdoutLine: ((String) -> Void)? = nil,
                    collectStdoutLines: Bool = false, secret: AdminPassword? = nil) -> RunResult {
        let proceed = state.with { st -> Bool in
            guard !st.cancelled else { return false }
            st.pid = 0; st.finished = false; st.inRun = true
            return true
        }
        guard proceed else {
            var r = RunResult()
            r.cancelled = true
            r.exitCode = 130
            return r
        }
        defer { state.with { $0.inRun = false } }
        var env = ProcessInfo.processInfo.environment
        env["MOLE_NO_COLOR"] = "1"
        env["NO_COLOR"] = "1"
        for (k, v) in extraEnvironment { env[k] = v }
        env["MOLE_SUDO_PASSWORD_FD"] = nil
        var result = RunResult()

        var secretReadFD: Int32 = -1
        defer { if secretReadFD >= 0 { close(secretReadFD) } }
        if let secret, secret.isSet {
            guard let fd = MoleRunner.secretPipe(secret) else {
                result.launchError = "Could not hand the admin password to \(executable)."
                result.exitCode = 127
                return result
            }
            secretReadFD = fd
            env["MOLE_SUDO_PASSWORD_FD"] = String(MoleRunner.passwordFD)
        }

        let outPipe = Pipe(), errPipe = Pipe()
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&fa, errPipe.fileHandleForWriting.fileDescriptor, 2)
        if secretReadFD >= 0 { posix_spawn_file_actions_adddup2(&fa, secretReadFD, MoleRunner.passwordFD) }
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        // Only the fds named above reach the child: no other run's pipes, and no secret pipe
        // another run is setting up at the same moment.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr) }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fa, &attr, argv, envp)
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        if secretReadFD >= 0 { close(secretReadFD); secretReadFD = -1 }
        guard rc == 0 else {
            result.launchError = "Cannot run \(executable): \(String(cString: strerror(rc)))"
            result.exitCode = 127
            return result
        }
        let timedOutFlag = Locked(false)
        // A cancel that came after the start check but before the pid was known signalled
        // nothing; send it now so no `mo` outlives a cancel (or the app's quit).
        if state.with({ st -> Bool in st.pid = pid; return st.cancelled }) { escalate() }
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
        let outLines = Locked([String]())
        let errSplit = Locked(LineSplitter())
        let outSplit = Locked(LineSplitter())
        let group = DispatchGroup()

        func emitErr(_ line: String) {
            lines.with { $0.append(line) }
            onStderrLine?(line)
        }
        func emitOut(_ line: String) {
            outLines.with { $0.append(line) }
            onStdoutLine?(line)
        }
        let splitStdout = onStdoutLine != nil || collectStdoutLines
        group.enter()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                if splitStdout, let rest = outSplit.with({ $0.finish() }) { emitOut(rest) }
                group.leave(); return
            }
            out.with { $0.append(d) }
            if splitStdout { for l in outSplit.with({ $0.feed(d) }) { emitOut(l) } }
        }
        group.enter()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                if let rest = errSplit.with({ $0.finish() }) { emitErr(rest) }
                group.leave()
                return
            }
            for l in errSplit.with({ $0.feed(d) }) { emitErr(l) }
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
        result.stdoutLines = outLines.with { $0 }
        let wasSignalled = (status & 0x7f) != 0
        result.exitCode = wasSignalled ? 128 + (status & 0x7f) : (status >> 8) & 0xff
        result.cancelled = state.with { $0.cancelled }
        result.timedOut = timedOutFlag.with { $0 }
        return result
    }
}
