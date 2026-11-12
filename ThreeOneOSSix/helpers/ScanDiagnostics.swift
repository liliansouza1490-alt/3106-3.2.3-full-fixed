import Foundation
import Darwin

/// Scan diagnostics log (WQManager parity): a dedicated thread writes with
/// raw `write(2)` so the log survives a wedged scan or main thread — a GCD
/// watchdog could end up blocked behind the same machinery it reports on.
/// Output: Documents/scan-diag-latest.log. Stages: enumerate / grant /
/// label / measure / drop / sort, each with counts and wall-clock.
enum ScanDiagnostics {
    static var logURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("scan-diag-latest.log")
    }

    private static let lock = NSLock()
    private static var fd: Int32 = -1
    private static var startedAt: Double = 0
    private static var stageStart: Double = 0
    private static var currentStage = ""
    private static var itemCount: Int64 = 0
    private static var watchPing: DispatchSourceTimer?

    /// Begin a diagnostic session: (re)opens the log on a serial queue and
    /// starts a watchdog timer that proves the main loop is alive.
    static func beginSession(backend: String) {
        lock.lock()
        defer { lock.unlock() }
        // Cancel any leaked watchdog from an un-ended previous session and
        // fence its handler off from the fresh state (it reads these statics).
        watchPing?.cancel()
        watchPing = nil
        if fd >= 0 { close(fd); fd = -1 }
        let path = logURL.path
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        startedAt = CFAbsoluteTimeGetCurrent()
        stageStart = startedAt
        itemCount = 0
        currentStage = ""
        writeLineUnlocked("session begin backend=\(backend) ts=\(Date())")

        // Watchdog: every 5s, write a heartbeat line. If scans hang, the log
        // shows the last stage and the missing heartbeat window. The handler
        // takes the lock: it reads currentStage/itemCount and writes through
        // writeLineUnlocked, all shared with the locked scan-thread writers.
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now() + 5, repeating: 5.0)
        source.setEventHandler { [weak source] in
            guard let source, !source.isCancelled else { return }
            lock.lock()
            defer { lock.unlock() }
            guard fd >= 0, watchPing === source else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            writeLineUnlocked(
                String(format: "watchdog alive %.1fs stage=%@ items=%lld", elapsed, currentStage, itemCount)
            )
        }
        source.resume()
        watchPing = source
    }

    static func stage(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if !currentStage.isEmpty {
            writeLineUnlocked(
                String(format: "stage end %@ %.3fs items=%lld", currentStage, now - stageStart, itemCount)
            )
        }
        currentStage = name
        stageStart = now
        itemCount = 0
        writeLineUnlocked("stage begin \(name)")
    }

    static func bumpItemCount(_ delta: Int64 = 1) {
        lock.lock()
        itemCount += delta
        lock.unlock()
    }

    static func note(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        writeLineUnlocked("note: \(line)")
    }

    static func endSession(summary: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if !currentStage.isEmpty {
            writeLineUnlocked(
                String(format: "stage end %@ %.3fs items=%lld", currentStage, now - stageStart, itemCount)
            )
            currentStage = ""
        }
        writeLineUnlocked(String(format: "session end %.3fs %@", now - startedAt, summary))
        watchPing?.cancel()
        watchPing = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// Must hold `lock`. Raw write(2): no Foundation buffering, so the line
    /// lands even when the process is half-wedged.
    private static func writeLineUnlocked(_ line: String) {
        guard fd >= 0 else { return }
        let payload = line + "\n"
        let data = payload.data(using: .utf8) ?? Data()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var remaining = raw.count
            var offset = 0
            while remaining > 0 {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), remaining)
                if written <= 0 {
                    if errno == EINTR { continue }
                    break
                }
                offset += written
                remaining -= written
            }
        }
    }
}
