import Foundation

@main
struct CommandRunnerTests {
    static func main() async throws {
        let runner = CommandRunner()
        let large = try await runner.run("/usr/bin/perl", ["-e", "print 'x' x 200000; print STDERR 'y' x 200000"])
        precondition(large.stdout.count == 200000 && large.stderr.count == 200000)
        do {
            _ = try await runner.run("/bin/sh", ["-c", "echo useful-error >&2; exit 7"])
            fatalError("Nonzero exit accepted")
        } catch { precondition(error.localizedDescription.contains("useful-error") && error.localizedDescription.contains("7")) }
        let start = Date()
        do {
            _ = try await runner.run("/usr/bin/perl", ["-e", "$SIG{TERM} = 'IGNORE'; sleep 30"], timeout: 0.2)
            fatalError("Timeout ignored")
        } catch { precondition(error.localizedDescription.contains("timed out")) }
        precondition(Date().timeIntervalSince(start) < 6)
        let task = Task { try await runner.run("/bin/sleep", ["30"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; fatalError("Cancellation ignored") }
        catch { precondition(error.localizedDescription.contains("cancelled")) }
        do { _ = try await runner.run("/nonexistent/jramdisk", []); fatalError("Launch failure ignored") }
        catch { }
        print("Command runner tests passed")
    }
}
