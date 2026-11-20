import Foundation

/// Runs notchtv_helper.py as a long-lived child process and speaks its line protocol
/// (see .ladder/PLAN.md). Messages are delivered on the main queue. Restarts the helper
/// if it dies, backing off up to 30 s.
final class HelperBridge {
    var onMessage: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?

    /// The app carries its own Python (see scripts/bundle-python.sh): nothing to install.
    static let python = Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 1
    private var stopping = false

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.python.path) }
    var isRunning: Bool { process != nil }

    func start() {
        guard process == nil, !stopping, isInstalled,
              let script = Bundle.main.url(forResource: "notchtv_helper", withExtension: "py")
        else { return }

        let p = Process()
        p.executableURL = Self.python
        // -I: ignore the user's PYTHON* variables and site-packages. -B: never write .pyc
        // files into the signed bundle (they're precompiled at build time).
        p.arguments = ["-I", "-B", "-u", script.path]
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Log.handle ?? FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.didExit(status: proc.terminationStatus) }
        }

        do {
            try p.run()
        } catch {
            Log.write("helper failed to launch: \(error)")
            scheduleRestart()
            return
        }
        process = p
        input = inPipe.fileHandleForWriting
        Log.write("helper started pid \(p.processIdentifier)")
    }

    func send(_ line: String) {
        guard let input else { return }
        do {
            try input.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            Log.write("helper write failed: \(error)")
        }
    }

    func stop() {
        stopping = true
        send("quit")
        process?.terminate()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            Log.write("helper: \(String(decoding: line, as: UTF8.self))")
            if obj["event"] as? String == "ready" { restartDelay = 1 }
            onMessage?(obj)
        }
    }

    private func didExit(status: Int32) {
        Log.write("helper exited (\(status))")
        process = nil
        input = nil
        buffer.removeAll()
        onExit?()
        if !stopping { scheduleRestart() }
    }

    private func scheduleRestart() {
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }
}

/// Appends to ~/Library/Logs/NotchTV.log (the helper's stderr goes there too).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NotchTV.log")

    static let handle: FileHandle? = {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    private static let stamp: ISO8601DateFormatter = ISO8601DateFormatter()

    static func write(_ message: String) {
        try? handle?.write(contentsOf: Data("\(stamp.string(from: Date())) \(message)\n".utf8))
    }
}
