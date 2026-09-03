// Stage 0B VirtioFS Isolation Prototype — minimal VZ helper.
//
// Purpose (ONLY): validate Apple Virtualization.framework VirtioFS directory
//   sharing for the Local MCP Dev Runner worktree-isolation design (P3.5), on
//   this Intel Mac, using a TEMP host directory only:
//     (a) build + validate an x86_64 Linux VM config with ZERO network devices
//         AND a single VirtioFS share tagged "lmdr-stage0b",
//     (b) actually start + stop such a VM, with the share attached,
//     (c) capture the guest console so guest evidence can reach the host,
//     (d) re-use the Stage 0A queue-affinity fix (no SIGILL).
//
// This is a prototype. It deliberately does NOT:
//   - integrate with the Local MCP Dev Runner / server.mjs / run_script,
//   - touch projects.json or the deployed runtime,
//   - mount a real worktree, configure networking, IPC/XPC, warm pools.
//
// Subcommands:
//   validate --kernel <url> --initrd <url> [--cmdline <str>] [--share <url>]
//       Build + validate the config; print JSON. Does NOT start a VM.
//   run --kernel <url> --initrd <url> [--cmdline <str>] [--share <url>]
//        [--run-seconds <n>] [--console-log <path>]
//       Build + validate + start the VM, capture the guest console, stop the VM.
//
// Exit codes: 0 = stage succeeded, 2 = stage failed (real error on stderr).
//
// QUEUE AFFINITY (inherited from Stage 0A Queue-Affinity Repair):
//   A VZVirtualMachine is bound to an associated dispatch queue; every property
//   access and lifecycle call must occur on it. Fix (方案 A): an explicit
//   dedicated serial DispatchQueue `vmQueue` is passed to
//   VZVirtualMachine(configuration:queue:); all create/start/state/stop run ON
//   vmQueue. A DispatchSpecificKey marker proves every step ran on that queue.
//
// VIRTIOFS API (correct form — DO NOT use the
//   VZSingleDirectoryShare(directory:readOnly:) convenience initializer):
//     let sharedDirectory = VZSharedDirectory(url: allowedDirURL, readOnly: false)
//     let share = VZSingleDirectoryShare(directory: sharedDirectory)
//     let fs = VZVirtioFileSystemDeviceConfiguration(tag: "lmdr-stage0b")
//     fs.share = share
//     config.directorySharingDevices = [fs]
//
// CONSOLE ATTACHMENT (Stage 0B Evidence-Pipeline Repair):
//   VZVirtioConsolePortConfiguration.isConsole = true alone is NOT enough —
//   VZConsolePortConfiguration.attachment defaults to nil, so guest console
//   output goes nowhere. We attach a VZFileHandleSerialPortAttachment backed by
//   a POSIX pipe:
//     fileHandleForWriting = pipe write end  -> guest output, host reads pipe[0]
//     fileHandleForReading = /dev/null       -> guest reads get immediate EOF
//   Capture is bounded (256 KiB) and drained non-blockingly via a DispatchSource
//   read source, so a chatty guest can never hang the host. No host environment
//   or secret material is ever read.

import Foundation
import Virtualization

// ----- tiny JSON writer (no dependencies) -----
func emit(_ dict: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    let text = String(data: data, encoding: .utf8) ?? "{}"
    print(text)
}

func fail(_ stage: String, _ message: String) -> Never {
    FileHandle.standardError.write(Data("\(stage) ERROR: \(message)\n".utf8))
    emit(["stage": stage, "ok": false, "error": message])
    exit(2)
}

// ----- argument parsing -----
func arg(_ name: String, from args: [String]) -> String? {
    if let idx = args.firstIndex(of: name), idx + 1 < args.count { return args[idx + 1] }
    return nil
}

let args = CommandLine.arguments
let sub = args.dropFirst().first ?? ""

let kernelURL: URL
let initrdURL: URL
if let k = arg("--kernel", from: args), let i = arg("--initrd", from: args) {
    kernelURL = URL(fileURLWithPath: k)
    initrdURL = URL(fileURLWithPath: i)
} else {
    fail(sub, "missing --kernel/--initrd (required for Stage 0B x86_64 Linux boot)")
}

// Stage 0B guest uses rdinit=/stage0b-init (the added initramfs entry), not
// Stage 0A's bare /bin/sh.
let cmdline = arg("--cmdline", from: args)
    ?? "console=hvc0 rdinit=/stage0b-init"
let runSeconds = Int(arg("--run-seconds", from: args) ?? "25") ?? 25
let consoleLogPath: String? = arg("--console-log", from: args)

// Optional VirtioFS share directory (host temp dir). Absent => no share device.
let shareURL: URL?
if let s = arg("--share", from: args) {
    shareURL = URL(fileURLWithPath: s)
} else {
    shareURL = nil
}

guard FileManager.default.fileExists(atPath: kernelURL.path) else {
    fail(sub, "kernel not found at \(kernelURL.path)")
}
guard FileManager.default.fileExists(atPath: initrdURL.path) else {
    fail(sub, "initrd not found at \(initrdURL.path)")
}
if let su = shareURL {
    // The share directory must exist at config-validate time (VZ checks it).
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: su.path, isDirectory: &isDir), isDir.boolValue else {
        fail(sub, "share directory not found or not a directory at \(su.path)")
    }
}

let VIRTIOFS_TAG = "lmdr-stage0b"
let CONSOLE_ATTACHMENT_NAME = "VZFileHandleSerialPortAttachment"
let CONSOLE_CAPTURE_LIMIT = 4194304 // 4 MiB (CONSOLE_CAPTURE_LIMIT_BYTES)

// ======================================================================
// Guest console capture: bounded (4 MiB), lock-protected buffer with
// continuous drain support.
// ======================================================================
final class ConsoleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var totalBytesSeen: Int = 0
    private var didTruncate = false
    let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if chunk.isEmpty { return }
        totalBytesSeen += chunk.count
        if buffer.count < limit {
            let room = limit - buffer.count
            if chunk.count > room {
                buffer.append(chunk.prefix(room))
                didTruncate = true
            } else {
                buffer.append(chunk)
            }
        } else {
            didTruncate = true
        }
    }

    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return buffer }
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return didTruncate }
    var captureBytes: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }
    var totalBytes: Int { lock.lock(); defer { lock.unlock() }; return totalBytesSeen }
}

// Allowed known guest keys (fail-closed, only recognized keys processed)
let knownGuestKeys: Set<String> = [
    "STAGE0B_GUEST_INIT_STARTED",
    "STAGE0B_GUEST_PID1",
    "STAGE0B_GUEST_BEFORE_VIRTIOFS",
    "VIRTIOFS_FSTYPE_LISTED",
    "VIRTIOFS_MODPROBE_RC",
    "VIRTIOFS_MOUNT_RC",
    "VIRTIOFS_MOUNT",
    "VIRTIOFS_MOUNT_ERROR",
    "VIRTIOFS_GUEST_SUPPORT",
    "GUEST_RESULTS_WRITABLE",
    "HOST_HOME_EXPOSED_TO_GUEST",
    "GUEST_HAS_VIRTIO_NET",
    "GUEST_INTERFACES",
    "PROBE_SPEC_LOADED",
    "GUEST_READ_HOST_MARKER",
    "GUEST_WRITE_MARKER",
    "DOTDOT_ESCAPE",
    "SYMLINK_ESCAPE_REL",
    "SYMLINK_ESCAPE_ABS",
    "ABSOLUTE_PATH_ESCAPE",
    "STAGE0B_GUEST_DONE"
]

// Host-only security keys that guest output is strictly forbidden to overwrite
let hostSecurityKeys: Set<String> = [
    "PROJECTS_JSON_MODIFIED",
    "RUNTIME_MODIFIED",
    "REAL_WORKTREE_TOUCHED",
    "STAGE0B_RESULT",
    "BLOCK_REASON",
    "GATE_A_IO",
    "GATE_B_SECURITY",
    "STAGE0B_SECURITY_GATE",
    "VIRTIOFS_PATH_ESCAPE_GATE",
    "SYMLINK_ESCAPE",
    "VIRTIOFS_HOST_TO_GUEST_READ",
    "VIRTIOFS_GUEST_TO_HOST_WRITE",
    "VM_START",
    "VM_RUNNING",
    "VM_STOP",
    "VM_FINAL_STATE",
    "VM_QUEUE_POLICY",
    "VM_STOP_TRIGGER",
    "VM_STOP_ORIGIN",
    "CLEANUP_PATH_GATE",
    "TEMP_FILES_CLEANED",
    "ORPHAN_PROCESS_COUNT"
]

// ======================================================================
// Incremental Inline Parser: parses lines on the fly across split chunks.
// ======================================================================
final class InlineParser: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLine = ""
    private var fields: [String: String] = [:]
    private var malformedLinesCount: Int = 0
    private var unknownKeysCount: Int = 0
    private var securityViolation: Bool = false

    private var guestInitConfirmed: Bool = false
    private var guestInitConfirmedTimestampMs: Int? = nil
    private var guestDoneConfirmed: Bool = false

    let startTimestamp: Date

    init(startTimestamp: Date) {
        self.startTimestamp = startTimestamp
    }

    func feed(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8) ?? String(data: chunk, encoding: .isoLatin1) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }

        let combined = pendingLine + text
        var lines = combined.components(separatedBy: "\n")
        pendingLine = lines.removeLast() // Incomplete remainder or empty if ended with newline
        let maxLineLength = 16384
        if pendingLine.count > maxLineLength {
            pendingLine = ""
            malformedLinesCount += 1
        }

        for rawLine in lines {
            processLineLocked(rawLine)
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !pendingLine.isEmpty {
            let line = pendingLine
            pendingLine = ""
            processLineLocked(line)
        }
    }

    private func processLineLocked(_ rawLine: String) {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return }

        if let eqIdx = line.firstIndex(of: "=") {
            let k = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)

            let isIdentifier = !k.isEmpty && k.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }

            if isIdentifier {
                if hostSecurityKeys.contains(k) {
                    securityViolation = true
                    malformedLinesCount += 1
                } else if knownGuestKeys.contains(k) {
                    // KEY deduplication: keep first occurrence
                    if fields[k] == nil {
                        fields[k] = v
                        if k == "STAGE0B_GUEST_INIT_STARTED" && v == "YES" {
                            if !guestInitConfirmed {
                                guestInitConfirmed = true
                                let ms = Int(Date().timeIntervalSince(startTimestamp) * 1000)
                                guestInitConfirmedTimestampMs = max(0, ms)
                            }
                        } else if k == "STAGE0B_GUEST_DONE" && v == "YES" {
                            guestDoneConfirmed = true
                        }
                    }
                } else if k.hasPrefix("STAGE0B_") || k.hasPrefix("VIRTIOFS_") || k.hasPrefix("GUEST_") || k.hasPrefix("PROBE_") {
                    unknownKeysCount += 1
                }
            } else if line.hasPrefix("STAGE0B_") || line.hasPrefix("VIRTIOFS_") || line.hasPrefix("GUEST_") {
                malformedLinesCount += 1
            }
        } else if line.hasPrefix("STAGE0B_") || line.hasPrefix("VIRTIOFS_") || line.hasPrefix("GUEST_") {
            malformedLinesCount += 1
        }
    }

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return guestDoneConfirmed
    }

    var isInitConfirmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return guestInitConfirmed
    }

    func snapshot() -> (
        fields: [String: String],
        malformed: Int,
        unknown: Int,
        secViolation: Bool,
        initConfirmed: Bool,
        initTimestampMs: Int?,
        doneConfirmed: Bool,
        parseStatus: String
    ) {
        lock.lock(); defer { lock.unlock() }
        let parseStatus: String
        let initStarted = fields["STAGE0B_GUEST_INIT_STARTED"]
        if securityViolation {
            parseStatus = "FAIL"
        } else if initStarted == "YES" || initStarted == "NO" {
            parseStatus = "PASS"
        } else {
            parseStatus = "INCONCLUSIVE"
        }
        return (fields, malformedLinesCount, unknownKeysCount, securityViolation, guestInitConfirmed, guestInitConfirmedTimestampMs, guestDoneConfirmed, parseStatus)
    }
}

// POSIX pipe: [0] = host reads guest output, [1] = VZ writes guest output.
var consolePipeFD: [Int32] = [-1, -1]
guard pipe(&consolePipeFD) == 0 else { fail(sub, "pipe() failed for console capture") }
let consoleReadFD = consolePipeFD[0]
let consoleWriteFD = consolePipeFD[1]

let consoleCapture = ConsoleCapture(limit: CONSOLE_CAPTURE_LIMIT)

// Host->guest side is /dev/null so a guest read on the console returns EOF
// instead of blocking the guest or the host forever.
let consoleAttachment: VZFileHandleSerialPortAttachment
var toGuestHandle: FileHandle? = nil
do {
    guard let toGuest = FileHandle(forReadingAtPath: "/dev/null") else {
        fail(sub, "cannot open /dev/null for console host->guest side")
    }
    toGuestHandle = toGuest
    let fromGuest = FileHandle(fileDescriptor: consoleWriteFD, closeOnDealloc: false)
    consoleAttachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: toGuest,
        fileHandleForWriting: fromGuest
    )
}

// Bounded capture + continuous non-blocking drain of the guest console into
// both consoleCapture and the incremental inline parser.
func startConsoleReader(parser: InlineParser) -> DispatchSourceRead {
    _ = fcntl(consoleReadFD, F_SETFL, O_NONBLOCK)
    let source = DispatchSource.makeReadSource(
        fileDescriptor: consoleReadFD,
        queue: DispatchQueue.global(qos: .utility)
    )
    source.setEventHandler {
        var buf = [UInt8](repeating: 0, count: 8192)
        let chunkSize = buf.count
        while true {
            let n = buf.withUnsafeMutableBytes { read(consoleReadFD, $0.baseAddress, chunkSize) }
            if n > 0 {
                let chunk = Data(buf[0..<n])
                consoleCapture.append(chunk)
                // Inline parser continuously feeds, even after capture buffer limit (4 MiB) is reached
                parser.feed(chunk)
            } else if n == 0 {
                source.cancel()
                return
            } else {
                break  // EAGAIN
            }
        }
    }
    source.resume()
    return source
}

// ======================================================================
// VM configuration
// ======================================================================
func buildConfig(consoleAttachment attach: VZSerialPortAttachment?) -> VZVirtualMachineConfiguration {
    let config = VZVirtualMachineConfiguration()

    config.platform = VZGenericPlatformConfiguration()

    let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
    bootLoader.commandLine = cmdline
    bootLoader.initialRamdiskURL = initrdURL
    config.bootLoader = bootLoader

    let maxCPU = VZVirtualMachineConfiguration.maximumAllowedCPUCount
    let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
    config.cpuCount = min(max(minCPU, 2), maxCPU)

    config.memorySize = 512 * 1024 * 1024

    // NETWORK: deliberately empty -> NETWORK_DEVICE_COUNT = 0 (Stage 0B requirement).
    config.networkDevices = []

    // One virtio console so the guest's console=hvc0 has a device, WITH a real
    // host-side attachment (the previous version left attachment = nil, which is
    // why every guest marker came back empty).
    let console = VZVirtioConsoleDeviceConfiguration()
    let consolePort = VZVirtioConsolePortConfiguration()
    consolePort.isConsole = true
    consolePort.attachment = attach
    console.ports[0] = consolePort
    config.consoleDevices = [console]

    // VIRTIOFS: attach a single directory share tagged lmdr-stage0b (correct API form).
    if let su = shareURL {
        let sharedDirectory = VZSharedDirectory(url: su, readOnly: false)
        let share = VZSingleDirectoryShare(directory: sharedDirectory)
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: VIRTIOFS_TAG)
        fs.share = share
        config.directorySharingDevices = [fs]
    }

    return config
}

// Map VZVirtualMachine.State to a clean string (rawValue-print is noisy).
func stateName(_ s: VZVirtualMachine.State) -> String {
    switch s {
    case .stopped:   return "stopped"
    case .running:   return "running"
    case .paused:    return "paused"
    case .error:     return "error"
    case .starting:  return "starting"
    case .pausing:   return "pausing"
    case .resuming:  return "resuming"
    case .stopping:  return "stopping"
    case .saving:    return "saving"
    case .restoring: return "restoring"
    @unknown default: return "unknown(\(s.rawValue))"
    }
}

// ======================================================================
if sub == "validate" {
    let isSupported = VZVirtualMachine.isSupported
    let config = buildConfig(consoleAttachment: consoleAttachment)
    var configValid = false
    var validateError: String? = nil
    do {
        try config.validate()
        configValid = true
    } catch {
        validateError = String(describing: error)
    }

    let virtiofsAttached = !config.directorySharingDevices.isEmpty
    let virtiofsTag = virtiofsAttached ? VIRTIOFS_TAG : "NOT_ATTACHED"
    let virtiofsShareMode = virtiofsAttached ? "read-write" : "NOT_ATTACHED"

    emit([
        "stage": "validate",
        "ok": configValid,
        "isSupported": isSupported,
        "cpuArch": "x86_64",
        "cpuCount": config.cpuCount,
        "memoryBytes": config.memorySize,
        "networkDeviceCount": config.networkDevices.count,
        "virtiofsDevice": virtiofsAttached ? "VZVirtioFileSystemDeviceConfiguration" : "NOT_ATTACHED",
        "virtiofsTag": virtiofsTag,
        "virtiofsShareMode": virtiofsShareMode,
        "consoleAttachment": CONSOLE_ATTACHMENT_NAME,
        "guestCommandLine": cmdline,
        "kernelPresent": true,
        "initrdPresent": true,
        "error": validateError as Any
    ])
    exit(configValid ? 0 : 2)
}

// ======================================================================
else if sub == "run" {
    // --- Queue-affinity plumbing (inherited Stage 0A Queue-Affinity Repair) ---
    let vmQueueKey = DispatchSpecificKey<String>()
    let vmQueueLabel = "com.localmcpdevrunner.stage0b.vz"
    let vmQueue = DispatchQueue(label: vmQueueLabel, qos: .userInitiated)
    vmQueue.setSpecific(key: vmQueueKey, value: vmQueueLabel)

    var vmStart = false
    var vmRunning = false
    var vmStop = false
    var vmFinalState = "unknown"
    var startErrorStr = ""
    var coldStartMs = -1

    var vmCreateQueue = "OTHER"
    var vmStartQueue = "OTHER"
    var vmStopQueue = "OTHER"

    func runStage() {
        let isSupported = VZVirtualMachine.isSupported
        if !isSupported {
            fail("run", "VZVirtualMachine.isSupported == false on this host")
        }

        let config = buildConfig(consoleAttachment: consoleAttachment)
        do { try config.validate() } catch {
            fail("run", "config.validate failed: \(error)")
        }

        var vm: VZVirtualMachine!
        vmQueue.sync {
            vmCreateQueue = (DispatchQueue.getSpecific(key: vmQueueKey) != nil) ? vmQueueLabel : "OTHER"
            vm = VZVirtualMachine(configuration: config, queue: vmQueue)
        }

        let startT = Date()
        let inlineParser = InlineParser(startTimestamp: startT)
        let consoleSource = startConsoleReader(parser: inlineParser)

        var vmStopTrigger = "UNKNOWN"
        let vmStopOrigin = "HOST_CONTROLLED"

        let startGroup = DispatchGroup()
        startGroup.enter()
        vmQueue.async {
            vmStartQueue = (DispatchQueue.getSpecific(key: vmQueueKey) != nil) ? vmQueueLabel : "OTHER"
            vm.start { result in
                switch result {
                case .success:
                    break
                case .failure(let e):
                    startErrorStr = String(describing: e)
                    fputs("run ERROR: vm.start() failed: \(startErrorStr)\n", stderr)
                }
                startGroup.leave()
            }
        }
        startGroup.wait()
        vmStart = startErrorStr.isEmpty

        var guestReportedDone = false

        if vmStart {
            for _ in 0..<40 {
                let grp = DispatchGroup(); grp.enter()
                var st: VZVirtualMachine.State = .stopped
                vmQueue.async { st = vm.state; grp.leave() }
                grp.wait()
                if st == .running { vmRunning = true; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            let runningT = Date()
            coldStartMs = Int(runningT.timeIntervalSince(startT) * 1000)

            // Wait for the guest to finish its probe, bounded by runSeconds.
            let deadline = Date().addingTimeInterval(Double(runSeconds))
            while Date() < deadline {
                if inlineParser.isDone {
                    guestReportedDone = true
                    vmStopTrigger = "GUEST_DONE_MARKER"
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if vmStopTrigger == "UNKNOWN" {
                vmStopTrigger = "HOST_TIMEOUT"
            }
            // Short settle so trailing console bytes land in the buffer.
            Thread.sleep(forTimeInterval: guestReportedDone ? 0.8 : 0.3)

            let stopGroup = DispatchGroup(); stopGroup.enter()
            vmQueue.async {
                vmStopQueue = (DispatchQueue.getSpecific(key: vmQueueKey) != nil) ? vmQueueLabel : "OTHER"
                vm.stop { error in
                    vmStop = (error == nil)
                    stopGroup.leave()
                }
            }
            stopGroup.wait()
            Thread.sleep(forTimeInterval: 0.5)
            let fg = DispatchGroup(); fg.enter()
            var finalStr = "unknown"
            vmQueue.async { finalStr = stateName(vm.state); fg.leave() }
            fg.wait()
            vmFinalState = finalStr
        } else {
            vmFinalState = "not-started"
            vmStopTrigger = "HOST_ERROR"
        }

        // --- drain the console: drop our write end so the reader sees EOF ---
        close(consoleWriteFD)
        for _ in 0..<20 {
            let before = consoleCapture.totalBytes
            Thread.sleep(forTimeInterval: 0.05)
            if consoleCapture.totalBytes == before { break }
        }
        consoleSource.cancel()
        close(consoleReadFD)
        toGuestHandle?.closeFile()
        Thread.sleep(forTimeInterval: 0.1)

        inlineParser.flush()
        let snap = inlineParser.snapshot()

        let consoleData = consoleCapture.snapshot()

        var consoleLogWritten = false
        if let logPath = consoleLogPath {
            do {
                try consoleData.write(to: URL(fileURLWithPath: logPath))
                consoleLogWritten = true
            } catch {
                consoleLogWritten = false
            }
        }

        let policy: String
        if vmCreateQueue == vmQueueLabel && vmStartQueue == vmQueueLabel && vmStopQueue == vmQueueLabel {
            policy = "PASS"
        } else if vmCreateQueue == vmQueueLabel {
            policy = "PARTIAL_CREATE_ONLY"
        } else {
            policy = "FAIL"
        }

        let virtiofsAttached = !config.directorySharingDevices.isEmpty
        let reportComplete = (snap.initConfirmed && snap.doneConfirmed) ? "YES" : "NO"

        emit([
            "stage": "run",
            "ok": vmStart && vmRunning && vmStop,
            "isSupported": isSupported,
            "cpuArch": "x86_64",
            "networkDeviceCount": config.networkDevices.count,
            "virtiofsDevice": virtiofsAttached ? "VZVirtioFileSystemDeviceConfiguration" : "NOT_ATTACHED",
            "virtiofsTag": virtiofsAttached ? VIRTIOFS_TAG : "NOT_ATTACHED",
            "virtiofsShareMode": virtiofsAttached ? "read-write" : "NOT_ATTACHED",
            "vmStart": vmStart,
            "vmRunning": vmRunning,
            "vmStop": vmStop,
            "vmFinalState": vmFinalState,
            "coldStartMs": coldStartMs,
            "vmQueueLabel": vmQueueLabel,
            "vmCreateQueue": vmCreateQueue,
            "vmStartQueue": vmStartQueue,
            "vmStopQueue": vmStopQueue,
            "vmQueuePolicy": policy,
            "vmStopTrigger": vmStopTrigger,
            "vmStopOrigin": vmStopOrigin,
            // --- guest console evidence (Stage 0B M1-M3 Inline & Continuous Drain) ---
            "consoleAttachment": CONSOLE_ATTACHMENT_NAME,
            "consoleTotalBytesSeen": consoleCapture.totalBytes,
            "consoleCaptureBytes": consoleCapture.captureBytes,
            "consoleCaptureTruncated": consoleCapture.truncated ? "YES" : "NO",
            "consoleLogWritten": consoleLogWritten,
            "guestCommandLine": cmdline,
            "guestReportParse": snap.parseStatus,
            "guestReportMalformedLines": snap.malformed,
            "guestReportUnknownKeys": snap.unknown,
            "guestInitConfirmedInline": snap.initConfirmed ? "YES" : "NO",
            "guestInitConfirmedInlineTimestampMs": snap.initTimestampMs.map(String.init) ?? "NOT_REPORTED",
            "guestInitStarted": snap.fields["STAGE0B_GUEST_INIT_STARTED"] ?? "NOT_REPORTED",
            "guestPid1": snap.fields["STAGE0B_GUEST_PID1"] ?? "NOT_REPORTED",
            "guestBeforeVirtiofs": snap.fields["STAGE0B_GUEST_BEFORE_VIRTIOFS"] ?? "NOT_REPORTED",
            "guestReportComplete": reportComplete,
            "virtiofsFstypeListed": snap.fields["VIRTIOFS_FSTYPE_LISTED"] ?? "NOT_REPORTED",
            "virtiofsModprobeRc": snap.fields["VIRTIOFS_MODPROBE_RC"] ?? "NOT_REPORTED",
            "virtiofsMountRc": snap.fields["VIRTIOFS_MOUNT_RC"] ?? "NOT_REPORTED",
            "virtiofsMount": snap.fields["VIRTIOFS_MOUNT"] ?? "NOT_REPORTED",
            "virtiofsMountError": snap.fields["VIRTIOFS_MOUNT_ERROR"] ?? "NOT_REPORTED",
            "virtiofsGuestSupport": snap.fields["VIRTIOFS_GUEST_SUPPORT"] ?? "NOT_REPORTED",
            "guestResultsWritable": snap.fields["GUEST_RESULTS_WRITABLE"] ?? "NOT_REPORTED",
            "hostHomeExposedToGuest": snap.fields["HOST_HOME_EXPOSED_TO_GUEST"] ?? "NOT_REPORTED",
            "guestHasVirtioNet": snap.fields["GUEST_HAS_VIRTIO_NET"] ?? "NOT_REPORTED",
            "guestInterfaces": snap.fields["GUEST_INTERFACES"] ?? "NOT_REPORTED",
            "probeSpecLoaded": snap.fields["PROBE_SPEC_LOADED"] ?? "NOT_REPORTED",
            "guestReadHostMarker": snap.fields["GUEST_READ_HOST_MARKER"] ?? "NOT_REPORTED",
            "guestWriteMarker": snap.fields["GUEST_WRITE_MARKER"] ?? "NOT_REPORTED",
            "dotdotEscape": snap.fields["DOTDOT_ESCAPE"] ?? "NOT_REPORTED",
            "symlinkEscapeRel": snap.fields["SYMLINK_ESCAPE_REL"] ?? "NOT_REPORTED",
            "symlinkEscapeAbs": snap.fields["SYMLINK_ESCAPE_ABS"] ?? "NOT_REPORTED",
            "absolutePathEscape": snap.fields["ABSOLUTE_PATH_ESCAPE"] ?? "NOT_REPORTED",
            "runSeconds": runSeconds,
            "error": startErrorStr as Any
        ])
        let stageOk = vmStart && vmRunning && vmStop
        exit(stageOk ? 0 : 2)
    }

    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        runStage()
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// ======================================================================
else {
    fail(sub, "unknown subcommand '\(sub)'; use 'validate' or 'run'")
}
