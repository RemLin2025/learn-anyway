import Testing
import Foundation
import Darwin
@testable import BraincellCore

/// Adversarial tests for the code runner. Each probe tries to escape; the matching "control" proves the sandbox
/// isn't merely broken (legitimate work in the run directory must still succeed).
@Suite(.serialized) struct SandboxRunnerTests {
    static let root: URL = { let u = FileManager.default.temporaryDirectory.appendingPathComponent("braincell-sbx-\(UUID().uuidString)"); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }()
    let runner = SandboxedCodeRunner(workRoot: SandboxRunnerTests.root)

    func finished(_ lang: String, _ code: String, name: String? = nil, stdin: String = "", extra: [CodeFile] = []) async -> CodeRunOutput {
        let file = name ?? (lang == "python" ? "main.py" : lang == "c" ? "main.c" : "Main.java")
        let r = await runner.run(CodeRunRequest(files: [CodeFile(name: file, language: lang, content: code)] + extra, language: lang, stdin: stdin))
        guard case .finished(let o) = r else { Issue.record("not finished: \(r)"); return CodeRunOutput(stdout: "", stderr: "", termination: .internalError("n/a"), compileOutput: nil, wallSeconds: 0, truncated: false) }
        return o
    }

    func leftoverProcesses() -> Int {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "braincell-sbx-"]
        let out = Pipe(); p.standardOutput = out; try? p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.split(separator: "\n").count ?? 0
    }

    var hasPython: Bool { runner.languages.contains(.python) }

    // MARK: Basics

    @Test func theMachineHasAllThreeToolchains() {
        #expect(runner.languages == [.python, .c, .java], "\(runner.unavailableReason ?? "")")
        #expect(runner.isAvailable)
    }

    @Test func pythonRunsWithStdin() async {
        let o = await finished("python", "n = int(input())\nprint(n * n)\nopen('out.txt','w').write('ok')\nprint(open('out.txt').read())", stdin: "12\n")
        #expect(o.termination == .exited(0) && o.stdout == "144\nok\n")           // control: writing inside the run directory works
    }

    @Test func compileAndRuntimeErrorsAreReportedAsTheLearnersProblem() async {
        let py = await finished("python", "print(1/0)")
        #expect(py.termination == .exited(1) && py.stderr.contains("ZeroDivisionError"))
        let c = await finished("c", "int main( { return 0; }")
        #expect(c.termination == .compileFailed && (c.compileOutput ?? "").contains("error"))
        let j = await finished("java", "public class Main { public static void main(String[] a) { int x = \"s\"; } }")
        #expect(j.termination == .compileFailed && (j.compileOutput ?? "").contains("error"))
        let ok = await finished("c", "#include <stdio.h>\nint main(void){ int n; scanf(\"%d\", &n); printf(\"%d\\n\", n*2); return 7; }", stdin: "21")
        #expect(ok.stdout == "42\n" && ok.termination == .exited(7))
        let jv = await finished("java", "import java.util.*; public class Main { public static void main(String[] a){ Scanner s = new Scanner(System.in); System.out.println(s.nextInt() + 1); System.exit(3); } }", stdin: "41")
        #expect(jv.stdout == "42\n" && jv.termination == .exited(3))
    }

    // MARK: Containment

    @Test func pythonCannotEscape() async throws {
        let secretDir = SandboxRunnerTests.root.deletingLastPathComponent().appendingPathComponent("braincell-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secretDir) }
        let secret = secretDir.appendingPathComponent("secret.txt"); try "TOPSECRET-4242".write(to: secret, atomically: true, encoding: .utf8)
        let escape = "/tmp/braincell-escape-\(UUID().uuidString)"
        setenv("BRAINCELL_TEST_SECRET", "hunter2", 1); defer { unsetenv("BRAINCELL_TEST_SECRET") }

        // A listener the sandboxed program will try to reach.
        let srv = socket(AF_INET, SOCK_STREAM, 0); defer { close(srv) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(srv, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(srv, 4)
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(srv, $0, &len) } }
        let port = UInt16(bigEndian: bound.sin_port)
        _ = fcntl(srv, F_SETFL, fcntl(srv, F_GETFL) | O_NONBLOCK)

        let code = """
        import os, socket, subprocess, sys
        def probe(name, f):
            try: r = f(); print(name, "ALLOWED", repr(r)[:40])
            except BaseException as e: print(name, "BLOCKED", type(e).__name__)
        probe("read_secret", lambda: open("\(secret.path)").read())
        probe("read_home", lambda: os.listdir(os.path.expanduser("~/..")))
        probe("read_users", lambda: os.listdir("/Users"))
        probe("read_etc", lambda: open("/etc/passwd").read())
        probe("write_outside", lambda: open("\(escape)", "w").write("x"))
        probe("write_secret_dir", lambda: open("\(secretDir.path)/new.txt", "w").write("x"))
        probe("network_connect", lambda: socket.create_connection(("127.0.0.1", \(port)), timeout=2))
        probe("dns", lambda: socket.gethostbyname("example.com"))
        probe("udp", lambda: socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"x", ("127.0.0.1", \(port))))
        probe("subprocess", lambda: subprocess.run(["/bin/echo", "hi"], capture_output=True))
        probe("os_system", lambda: os.system("echo hi") == 0)
        probe("fork", lambda: os.fork())
        probe("exec_sh", lambda: os.execv("/bin/sh", ["sh", "-c", "echo pwned"]))
        probe("kill_parent", lambda: os.kill(os.getppid(), 0))
        probe("symlink_read", lambda: (os.symlink("\(secret.path)", "link"), open("link").read())[1])
        probe("hardlink", lambda: os.link("\(secret.path)", "hl"))
        probe("chmod_outside", lambda: os.chmod("\(secretDir.path)", 0o777))
        print("secret_env", os.environ.get("BRAINCELL_TEST_SECRET"))
        print("env_keys", sorted(os.environ.keys()))
        print("cwd_is_workdir", os.getcwd().startswith("\(SandboxedCodeRunner.realpath(SandboxRunnerTests.root.path))/braincell-run-"))
        open("control.txt", "w").write("fine"); print("control_write", open("control.txt").read())
        """
        let o = await finished("python", code)
        #expect(o.termination == .exited(0), "\(o.stderr)")
        for name in ["read_secret", "read_home", "read_users", "read_etc", "write_outside", "write_secret_dir", "network_connect", "dns", "udp", "subprocess", "fork", "exec_sh", "kill_parent", "symlink_read", "hardlink", "chmod_outside"] {
            #expect(o.stdout.contains("\(name) BLOCKED"), "\(name) was not blocked: \(o.stdout)")
        }
        #expect(o.stdout.contains("os_system") && !o.stdout.contains("os_system ALLOWED True"))
        #expect(!o.stdout.contains("TOPSECRET") && !o.stdout.contains("pwned") && !o.stdout.contains("hunter2"))
        #expect(o.stdout.contains("secret_env None"))
        #expect(o.stdout.contains("cwd_is_workdir True") && o.stdout.contains("control_write fine"))
        // Side effects: nothing was created outside, no connection arrived, the secret is intact.
        #expect(!FileManager.default.fileExists(atPath: escape) && !FileManager.default.fileExists(atPath: secretDir.appendingPathComponent("new.txt").path))
        #expect(try String(contentsOf: secret, encoding: .utf8) == "TOPSECRET-4242")
        #expect(accept(srv, nil, nil) < 0, "the sandboxed program reached a local TCP listener")
        let line = o.stdout.split(separator: "\n").first { $0.hasPrefix("env_keys") }.map(String.init) ?? ""
        let keys = Set(line.dropFirst("env_keys ".count).filter { !"[]' ".contains($0) }.split(separator: ",").map(String.init))
        #expect(keys.isSubset(of: ["HOME", "LANG", "PATH", "PWD", "PYTHONDONTWRITEBYTECODE", "PYTHONIOENCODING", "SHLVL", "TMPDIR", "__CF_USER_TEXT_ENCODING", "_"]), Comment(rawValue: line))
    }

    @Test func cCannotEscape() async throws {
        let secretDir = SandboxRunnerTests.root.deletingLastPathComponent().appendingPathComponent("braincell-csecret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secretDir) }
        try "CSECRET".write(to: secretDir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        let escape = "/tmp/braincell-cescape-\(UUID().uuidString)"
        let o = await finished("c", """
        #include <stdio.h>
        #include <stdlib.h>
        #include <unistd.h>
        #include <sys/socket.h>
        #include <netinet/in.h>
        #include <arpa/inet.h>
        int main(void) {
          FILE *f = fopen("\(secretDir.path)/s.txt", "r"); printf("read:%s\\n", f ? "ALLOWED" : "BLOCKED");
          f = fopen("/etc/passwd", "r"); printf("etc:%s\\n", f ? "ALLOWED" : "BLOCKED");
          f = fopen("\(escape)", "w"); printf("write:%s\\n", f ? "ALLOWED" : "BLOCKED");
          int s = socket(AF_INET, SOCK_STREAM, 0); struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons(9); a.sin_addr.s_addr = inet_addr("127.0.0.1");
          printf("net:%s\\n", connect(s, (struct sockaddr*)&a, sizeof a) == 0 ? "ALLOWED" : "BLOCKED");
          printf("fork:%s\\n", fork() < 0 ? "BLOCKED" : "ALLOWED");
          printf("system:%d\\n", system("echo pwned"));
          f = fopen("ok.txt", "w"); printf("control:%s\\n", f ? "OK" : "FAIL"); return 0; }
        """)
        #expect(o.termination == .exited(0), "\(o.stderr) \(o.compileOutput ?? "")")
        for line in ["read:BLOCKED", "etc:BLOCKED", "write:BLOCKED", "net:BLOCKED", "fork:BLOCKED", "control:OK"] { #expect(o.stdout.contains(line), "\(line) missing in \(o.stdout)") }
        #expect(!o.stdout.contains("pwned") && !o.stdout.contains("system:0"))
        #expect(!FileManager.default.fileExists(atPath: escape))
    }

    @Test func javaCannotEscape() async throws {
        let secretDir = SandboxRunnerTests.root.deletingLastPathComponent().appendingPathComponent("braincell-jsecret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secretDir) }
        try "JSECRET".write(to: secretDir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        let escape = "/tmp/braincell-jescape-\(UUID().uuidString)"
        let o = await finished("java", """
        import java.nio.file.*; import java.net.*; import java.util.*;
        public class Main {
          static void probe(String n, Runnable r) { try { r.run(); System.out.println(n + " ALLOWED"); } catch (Throwable e) { System.out.println(n + " BLOCKED"); } }
          public static void main(String[] a) throws Exception {
            probe("read", () -> { try { Files.readString(Path.of("\(secretDir.path)/s.txt")); } catch (Exception e) { throw new RuntimeException(e); } });
            probe("etc", () -> { try { Files.readString(Path.of("/etc/passwd")); } catch (Exception e) { throw new RuntimeException(e); } });
            probe("write", () -> { try { Files.writeString(Path.of("\(escape)"), "x"); } catch (Exception e) { throw new RuntimeException(e); } });
            probe("net", () -> { try { new Socket("127.0.0.1", 9); } catch (Exception e) { throw new RuntimeException(e); } });
            probe("exec", () -> { try { Runtime.getRuntime().exec(new String[]{"/bin/echo", "pwned"}).waitFor(); } catch (Exception e) { throw new RuntimeException(e); } });
            Files.writeString(Path.of("ok.txt"), "fine"); System.out.println("control " + Files.readString(Path.of("ok.txt")));
          } }
        """)
        #expect(o.termination == .exited(0), "\(o.stderr) \(o.compileOutput ?? "")")
        for n in ["read", "etc", "write", "net", "exec"] { #expect(o.stdout.contains("\(n) BLOCKED"), "\(n): \(o.stdout)") }
        #expect(o.stdout.contains("control fine") && !o.stdout.contains("pwned"))
        #expect(!FileManager.default.fileExists(atPath: escape))
    }

    // MARK: Resource limits

    @Test func infiniteLoopsAreKilledAndLeaveNoProcesses() async {
        let o = await finished("python", "while True: pass")
        #expect(o.termination == .timedOut && o.wallSeconds < 6.5, "\(o.termination) after \(o.wallSeconds)s")
        let c = await finished("c", "int main(void){ for(;;){} }")
        #expect(c.termination == .timedOut)
        let j = await finished("java", "public class Main { public static void main(String[] a){ while(true){} } }")
        #expect(j.termination == .timedOut)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(leftoverProcesses() == 0)
    }

    @Test func forkBombIsHarmless() async {
        let o = await finished("python", "import os\nn=0\nfor _ in range(200):\n    try:\n        if os.fork()==0: os._exit(0)\n        n+=1\n    except OSError:\n        break\nprint('forked', n)")
        #expect(o.stdout == "forked 0\n" && o.wallSeconds < 3)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(leftoverProcesses() == 0)
    }

    @Test func outputFloodsAreCapped() async {
        let o = await finished("python", "while True: print('x' * 1000)")
        #expect(o.termination == .outputLimit && o.stdout.utf8.count <= SandboxLimits.run.maxOutputBytes && o.truncated)
        let e = await finished("python", "import sys\nwhile True: sys.stderr.write('e' * 1000)")
        #expect(e.termination == .outputLimit && e.stderr.utf8.count <= SandboxLimits.run.maxOutputBytes)
    }

    @Test func memoryHogsAreKilled() async {
        let o = await finished("python", "a = []\nwhile True: a.append(b'x' * (16 << 20) + bytes(a.__len__() % 250))")
        #expect(o.termination == .memoryLimit, "\(o.termination) after \(o.wallSeconds)s")
        #expect(o.wallSeconds < 5)
        let j = await finished("java", "import java.util.*; public class Main { public static void main(String[] x){ List<long[]> l = new ArrayList<>(); while(true) l.add(new long[1<<20]); } }")
        if case .exited(let c) = j.termination { #expect(c != 0) } else { #expect(j.termination == .memoryLimit || j.termination == .timedOut) }
    }

    @Test func diskFillingIsStopped() async {
        let o = await finished("python", "f = open('big', 'wb')\nfor _ in range(200): f.write(b'0' * (1 << 20))\nf.close()\nprint('wrote all')")
        #expect(!o.stdout.contains("wrote all"), "the file-size limit didn't stop a 200 MB write: \(o.termination)")
    }

    @Test func crashesAreReportedNotFatal() async {
        let c = await finished("c", "int main(void){ int *p = 0; *p = 1; return 0; }")
        if case .signaled = c.termination {} else { Issue.record("a crashing program should end with a signal, got \(c.termination)") }   // SIGSEGV or SIGTRAP depending on codegen
        let again = await finished("python", "print('still fine')")
        #expect(again.stdout == "still fine\n")
    }

    // MARK: Run directory and inputs

    @Test func runDirectoriesAreAlwaysRemoved() async {
        _ = await finished("python", "open('x','w').write('1')")
        _ = await finished("python", "while True: pass")
        _ = await finished("c", "int main(void){ return 0; }")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: SandboxRunnerTests.root.path).filter { $0.hasPrefix("braincell-run-") }) ?? ["?"]
        #expect(left.isEmpty, "\(left)")
    }

    @Test func badFileNamesNeverReachTheSandbox() async {
        for name in ["../evil.py", "a/b.py", ".hidden.py", "x.txt", "bad name.py", "evil\".py", "main.py\n", String(repeating: "a", count: 80) + ".py", ""] {
            let r = await runner.run(CodeRunRequest(files: [CodeFile(name: name, language: "python", content: "print(1)")], language: "python"))
            if case .finished(let o) = r { if case .internalError = o.termination {} else { Issue.record("accepted file name \(name.debugDescription): \(o)") } } else { Issue.record("unexpected \(r)") }
        }
        let dup = await runner.run(CodeRunRequest(files: [CodeFile(name: "a.py", language: "python", content: ""), CodeFile(name: "a.py", language: "python", content: "")], language: "python"))
        if case .finished(let o) = dup, case .internalError = o.termination {} else { Issue.record("duplicate accepted") }
        let big = await runner.run(CodeRunRequest(files: [CodeFile(name: "a.py", language: "python", content: String(repeating: "#", count: 300_000))], language: "python"))
        if case .finished(let o) = big, case .internalError = o.termination {} else { Issue.record("huge file accepted") }
        let wrongLang = await runner.run(CodeRunRequest(files: [CodeFile(name: "a.py", language: "ruby", content: "")], language: "ruby"))
        #expect(wrongLang == .unavailable(reason: runner.unavailableReason ?? "Running ruby code isn’t supported."))
    }

    @Test func concurrentRunsDoNotInterfere() async {
        let outs = await withTaskGroup(of: String.self) { g in
            for i in 0..<5 { g.addTask { await self.finished("python", "import time; time.sleep(0.2); open('f','w').write('\(i)'); print(open('f').read())").stdout } }
            var r: [String] = []; for await s in g { r.append(s) }; return r.sorted()
        }
        #expect(outs == ["0\n", "1\n", "2\n", "3\n", "4\n"])
    }

    @Test func missingSandboxMeansNothingRuns() async {
        let none = SandboxedCodeRunner(toolchain: .init(), workRoot: SandboxRunnerTests.root)
        #expect(!none.isAvailable && none.languages.isEmpty)
        let r = await none.run(CodeRunRequest(files: [CodeFile(name: "main.py", language: "python", content: "print(1)")], language: "python"))
        if case .unavailable = r {} else { Issue.record("ran without a toolchain: \(r)") }
        #expect(await none.runTests(CodeRunRequest(files: [], language: "python"), tests: [CodeTest(name: "t", input: "", expectedOutput: "")]) == .unavailable(reason: none.unavailableReason!))
    }

    // MARK: Test running

    @Test func testsReportPerCaseOutcomesAndHideHiddenOnes() async {
        let code = "n = int(input())\nif n == 13: raise SystemExit(5)\nif n == 99:\n    while True: pass\nprint(n * 2 if n != 4 else 0)"
        let tests = [CodeTest(name: "double", input: "2\n", expectedOutput: "4"), CodeTest(name: "wrong", input: "4\n", expectedOutput: "8"),
                     CodeTest(name: "crash", input: "13\n", expectedOutput: "26", hidden: true), CodeTest(name: "hang", input: "99\n", expectedOutput: "198"),
                     CodeTest(name: "spaces", input: "3\n", expectedOutput: "6  \n\n")]
        let rep = await runner.runTests(CodeRunRequest(files: [CodeFile(name: "main.py", language: "python", content: code)], language: "python"), tests: tests)
        guard case .ran(let o) = rep else { Issue.record("\(rep)"); return }
        #expect(o.map(\.status) == [.passed, .failed, .crashed, .timedOut, .passed])
        #expect(rep.passedCount == 2 && rep.totalCount == 5)
        #expect(o[2].hidden && o[2].input == nil && o[2].expected == nil && o[2].actual.isEmpty)    // hidden tests reveal nothing
        #expect(o[1].expected == "8" && o[1].actual == "0\n")
    }

    @Test func testsRunForCAndJavaAndCompileErrorsAreSeparate() async {
        let c = "#include <stdio.h>\nint main(void){ int a,b; scanf(\"%d %d\",&a,&b); printf(\"%d\\n\",a+b); return 0; }"
        let t = [CodeTest(name: "1", input: "1 2", expectedOutput: "3"), CodeTest(name: "2", input: "40 2", expectedOutput: "42")]
        #expect(await runner.runTests(CodeRunRequest(files: [CodeFile(name: "main.c", language: "c", content: c)], language: "c"), tests: t).passedCount == 2)
        let j = "import java.util.*; public class Main { public static void main(String[] x){ Scanner s=new Scanner(System.in); System.out.println(s.nextInt()+s.nextInt()); } }"
        #expect(await runner.runTests(CodeRunRequest(files: [CodeFile(name: "Main.java", language: "java", content: j)], language: "java"), tests: t).passedCount == 2)
        if case .compileError(let m) = await runner.runTests(CodeRunRequest(files: [CodeFile(name: "main.c", language: "c", content: "int main(")], language: "c"), tests: t) { #expect(m.contains("error")) } else { Issue.record("expected compile error") }
        if case .internalError = await runner.runTests(CodeRunRequest(files: [CodeFile(name: "main.py", language: "python", content: "")], language: "python"), tests: []) {} else { Issue.record("empty tests accepted") }
    }
}
