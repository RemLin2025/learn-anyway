import Foundation
import Darwin

public struct SandboxLimits: Sendable, Equatable {
    public var wallSeconds: Double
    public var cpuSeconds: Int
    public var maxOutputBytes: Int
    public var maxMemoryBytes: Int
    public var maxFileBytes: Int
    public var openFiles: Int

    public static let run = SandboxLimits(wallSeconds: 5, cpuSeconds: 4, maxOutputBytes: 64 * 1024, maxMemoryBytes: 256 << 20, maxFileBytes: 8 << 20, openFiles: 64)
    public static let compile = SandboxLimits(wallSeconds: 30, cpuSeconds: 25, maxOutputBytes: 64 * 1024, maxMemoryBytes: 1 << 30, maxFileBytes: 64 << 20, openFiles: 256)
    public init(wallSeconds: Double, cpuSeconds: Int, maxOutputBytes: Int, maxMemoryBytes: Int, maxFileBytes: Int, openFiles: Int) {
        self.wallSeconds = wallSeconds; self.cpuSeconds = cpuSeconds; self.maxOutputBytes = maxOutputBytes
        self.maxMemoryBytes = maxMemoryBytes; self.maxFileBytes = maxFileBytes; self.openFiles = openFiles
    }
}

public enum Termination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut
    case outputLimit
    case memoryLimit
    case failedToStart(String)
}

public struct SpawnResult: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var termination: Termination
    public var wallSeconds: Double
    public var outputTruncated: Bool
}

/// Starts one process in its own process group, feeds it stdin, and enforces wall-clock, output and memory limits
/// from outside. It never runs anything in the Braincell process itself. Everything the child may do is decided by
/// the Seatbelt profile and rlimits set by the trusted launcher script (see `SandboxedCodeRunner`).
enum ProcessSupervisor {

    static func run(executable: String, arguments: [String], environment: [String: String], workingDirectory: String,
                    stdin: Data, limits: SandboxLimits) -> SpawnResult {
        let start = Date()
        func fail(_ m: String) -> SpawnResult { SpawnResult(stdout: Data(), stderr: Data(), termination: .failedToStart(m), wallSeconds: 0, outputTruncated: false) }

        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { return fail("pipe() failed") }
        for fd in [inPipe[1], outPipe[0], errPipe[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fa, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&fa, workingDirectory)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New process group (so the whole tree can be killed) and close every fd the child wasn't explicitly given.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | 0x4000 /* POSIX_SPAWN_CLOEXEC_DEFAULT */))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fa, &attr, argv, envp)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else { close(inPipe[1]); close(outPipe[0]); close(errPipe[0]); return fail("posix_spawn failed: \(String(cString: strerror(rc)))") }

        var out = Data(), err = Data()
        var outOpen = true, errOpen = true, inOpen = true, written = 0
        var termination: Termination?
        var truncated = false
        var status: Int32 = 0, exited = false
        var lastMemCheck = Date.distantPast
        let deadline = start.addingTimeInterval(limits.wallSeconds)
        if stdin.isEmpty { close(inPipe[1]); inOpen = false }

        func killGroup() { kill(-pid, SIGKILL) }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        loop: while true {
            var fds: [pollfd] = []
            if outOpen { fds.append(pollfd(fd: outPipe[0], events: Int16(POLLIN), revents: 0)) }
            if errOpen { fds.append(pollfd(fd: errPipe[0], events: Int16(POLLIN), revents: 0)) }
            if inOpen { fds.append(pollfd(fd: inPipe[1], events: Int16(POLLOUT), revents: 0)) }
            if !fds.isEmpty { poll(&fds, nfds_t(fds.count), 20) } else { usleep(20_000) }

            for f in fds where f.revents != 0 {
                if f.fd == inPipe[1] {
                    let n = stdin.withUnsafeBytes { raw in write(inPipe[1], raw.baseAddress!.advanced(by: written), min(raw.count - written, 16 * 1024)) }
                    if n > 0 { written += n }
                    if n < 0 && errno != EAGAIN { close(inPipe[1]); inOpen = false }
                    if written >= stdin.count { close(inPipe[1]); inOpen = false }
                } else {
                    let isOut = f.fd == outPipe[0]
                    let n = read(f.fd, &buffer, buffer.count)
                    if n > 0 {
                        let room = limits.maxOutputBytes - (isOut ? out.count : err.count)
                        if n > room { truncated = true; termination = termination ?? .outputLimit }
                        if room > 0 { let chunk = buffer[0..<min(n, room)]; if isOut { out.append(contentsOf: chunk) } else { err.append(contentsOf: chunk) } }
                    } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                        if isOut { outOpen = false } else { errOpen = false }
                    }
                }
            }

            if !exited {
                var st: Int32 = 0
                if waitpid(pid, &st, WNOHANG) == pid { exited = true; status = st }
            }
            if termination != nil { killGroup(); break loop }
            if Date() >= deadline && (!exited || outOpen || errOpen) { termination = .timedOut; killGroup(); break loop }
            if Date().timeIntervalSince(lastMemCheck) > 0.05 && !exited {
                lastMemCheck = Date()
                if groupResidentBytes(pgid: pid) > UInt64(limits.maxMemoryBytes) { termination = .memoryLimit; killGroup(); break loop }
            }
            if exited && !outOpen && !errOpen { break loop }
            if exited && Date().timeIntervalSince(start) > limits.wallSeconds + 1 { break loop }   // a stray grandchild holds the pipes
            if exited { killGroup() }                                                             // reap anything left in the group
        }

        killGroup()
        if !exited { var st: Int32 = 0; waitpid(pid, &st, 0); status = st; exited = true }
        // Drain whatever is still buffered (bounded).
        for (fd, isOut) in [(outPipe[0], true), (errPipe[0], false)] {
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                let room = limits.maxOutputBytes - (isOut ? out.count : err.count)
                if room > 0 { let c = buffer[0..<min(n, room)]; if isOut { out.append(contentsOf: c) } else { err.append(contentsOf: c) } } else { truncated = true }
            }
        }
        close(outPipe[0]); close(errPipe[0]); if inOpen { close(inPipe[1]) }

        if termination == nil {
            let signaled = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
            termination = signaled ? .signaled(status & 0x7f) : .exited((status >> 8) & 0xff)
        }
        return SpawnResult(stdout: out, stderr: err, termination: termination!, wallSeconds: Date().timeIntervalSince(start), outputTruncated: truncated)
    }

    static func residentBytes(_ pid: pid_t) -> UInt64 {
        var ti = proc_taskinfo()
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 ? ti.pti_resident_size : 0
    }

    /// Resident memory of the main process plus every other process in its group (compilers spawn helpers).
    static func groupResidentBytes(pgid: pid_t) -> UInt64 {
        var total = residentBytes(pgid)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), nil, 0)
        guard bytes > 0 else { return total }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 16)
        let got = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return total }
        for p in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where p > 0 && p != pgid { total += residentBytes(p) }
        return total
    }
}
