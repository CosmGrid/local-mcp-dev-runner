import Foundation
import Virtualization
import Darwin

struct ProbeManifest: Codable {
    let allowedRead: String
    let allowedWriteTarget: String
    let deniedSiblingRead: String
    let deniedParentRead: String
    let deniedHomeSsh: String
    let deniedHomeAws: String
    let deniedHomeConfig: String
    let deniedRuntimeSentinel: String
    let deniedProjectsSentinel: String
    let deniedSymlinkEscapeRel: String
    let deniedSymlinkEscapeAbs: String
    let deniedAbsolutePath: String
    let deniedWriteSibling: String
    let deniedWriteParent: String
    let deniedWriteHome: String
    let tcpPort: Int
    let helperPath: String
    let kernelPath: String
    let initrdPath: String
    let sharePath: String
    let virtiofsTag: String
}

struct ProbeResult: Codable {
    let status: String       // PASS, FAIL, INCONCLUSIVE
    let errnoVal: Int32
    let reason: String
}

struct ChildProbeResult: Codable {
    let childAllowedRead: String
    let childDeniedSentinelRead: String
    let childInheritsContainment: String
}

func probeDeniedRead(path: String) -> ProbeResult {
    let fd = open(path, O_RDONLY)
    if fd >= 0 {
        close(fd)
        return ProbeResult(status: "FAIL", errnoVal: 0, reason: "LEAKED_FILE_ACCESSIBLE")
    }
    let err = errno
    if err == EPERM || err == EACCES {
        return ProbeResult(status: "PASS", errnoVal: err, reason: "POLICY_DENIED")
    } else if err == ENOENT {
        return ProbeResult(status: "INCONCLUSIVE", errnoVal: err, reason: "NOT_FOUND")
    } else {
        return ProbeResult(status: "INCONCLUSIVE", errnoVal: err, reason: "OTHER_ERRNO_\(err)")
    }
}

func probeDeniedWrite(path: String) -> ProbeResult {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 {
        close(fd)
        unlink(path)
        return ProbeResult(status: "FAIL", errnoVal: 0, reason: "WRITE_PERMITTED")
    }
    let err = errno
    if err == EPERM || err == EACCES || err == EROFS {
        return ProbeResult(status: "PASS", errnoVal: err, reason: "POLICY_DENIED")
    } else if err == ENOENT {
        return ProbeResult(status: "INCONCLUSIVE", errnoVal: err, reason: "NOT_FOUND")
    } else {
        return ProbeResult(status: "INCONCLUSIVE", errnoVal: err, reason: "OTHER_ERRNO_\(err)")
    }
}

func probeAllowedRead(path: String) -> ProbeResult {
    let fd = open(path, O_RDONLY)
    if fd < 0 {
        return ProbeResult(status: "FAIL", errnoVal: errno, reason: "ALLOWED_READ_FAILED_\(errno)")
    }
    var buf = [UInt8](repeating: 0, count: 512)
    let n = read(fd, &buf, buf.count)
    close(fd)
    if n > 0 {
        return ProbeResult(status: "PASS", errnoVal: 0, reason: "READ_OK")
    } else {
        return ProbeResult(status: "FAIL", errnoVal: 0, reason: "EMPTY_FILE")
    }
}

func probeAllowedWrite(path: String) -> ProbeResult {
    let payload = "STAGE0D_WRITE_TEST_\(arc4random())\n"
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd < 0 {
        return ProbeResult(status: "FAIL", errnoVal: errno, reason: "ALLOWED_WRITE_FAILED_\(errno)")
    }
    let written = payload.utf8.withContiguousStorageIfAvailable { ptr in
        write(fd, ptr.baseAddress, ptr.count)
    } ?? -1
    close(fd)
    if written <= 0 {
        return ProbeResult(status: "FAIL", errnoVal: 0, reason: "WRITE_FAILED")
    }

    let rfd = open(path, O_RDONLY)
    if rfd < 0 {
        return ProbeResult(status: "FAIL", errnoVal: errno, reason: "READBACK_OPEN_FAILED")
    }
    var buf = [UInt8](repeating: 0, count: 512)
    let n = read(rfd, &buf, buf.count)
    close(rfd)
    unlink(path)

    if n > 0 {
        return ProbeResult(status: "PASS", errnoVal: 0, reason: "WRITE_AND_READ_OK")
    } else {
        return ProbeResult(status: "FAIL", errnoVal: 0, reason: "READBACK_EMPTY")
    }
}

func probeNetworkConnect(port: Int) -> ProbeResult {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    if sock < 0 {
        let err = errno
        if err == EPERM || err == EACCES {
            return ProbeResult(status: "PASS", errnoVal: err, reason: "SOCKET_POLICY_DENIED")
        }
        return ProbeResult(status: "FAIL", errnoVal: err, reason: "SOCKET_CREATION_FAILED_\(err)")
    }
    defer { close(sock) }

    _ = fcntl(sock, F_SETFL, O_NONBLOCK)

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    if rc == 0 {
        return ProbeResult(status: "FAIL", errnoVal: 0, reason: "CONNECTED_TO_NETWORK")
    }

    let err = errno
    if err == EPERM || err == EACCES {
        return ProbeResult(status: "PASS", errnoVal: err, reason: "CONNECT_POLICY_DENIED")
    } else if err == EINPROGRESS {
        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollRc = poll(&pfd, 1, 500)
        if pollRc > 0 {
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len)
            if soError == 0 {
                return ProbeResult(status: "FAIL", errnoVal: 0, reason: "CONNECTED_TO_NETWORK")
            } else if soError == EPERM || soError == EACCES {
                return ProbeResult(status: "PASS", errnoVal: soError, reason: "ASYNC_CONNECT_POLICY_DENIED")
            } else if soError == ECONNREFUSED {
                return ProbeResult(status: "INCONCLUSIVE", errnoVal: soError, reason: "CONNECTION_REFUSED_CANNOT_PROVE_SANDBOX")
            } else {
                return ProbeResult(status: "INCONCLUSIVE", errnoVal: soError, reason: "ASYNC_CONNECT_ERR_\(soError)")
            }
        } else {
            return ProbeResult(status: "INCONCLUSIVE", errnoVal: 0, reason: "CONNECT_TIMED_OUT")
        }
    } else if err == ECONNREFUSED {
        return ProbeResult(status: "INCONCLUSIVE", errnoVal: err, reason: "CONNECTION_REFUSED_CANNOT_PROVE_SANDBOX")
    } else {
        return ProbeResult(status: "INCONCLUSIVE", errnoVal: err, reason: "CONNECT_ERR_\(err)")
    }
}

func runHostContainmentProbes(manifest: ProbeManifest, phasePrefix: String) -> ([String: Any], Bool) {
    var phaseMap: [String: Any] = [:]

    let allowedRead = probeAllowedRead(path: manifest.allowedRead)
    let allowedWrite = probeAllowedWrite(path: manifest.allowedWriteTarget)
    let deniedSibling = probeDeniedRead(path: manifest.deniedSiblingRead)
    let deniedParent = probeDeniedRead(path: manifest.deniedParentRead)
    let deniedHomeSsh = probeDeniedRead(path: manifest.deniedHomeSsh)
    let deniedHomeAws = probeDeniedRead(path: manifest.deniedHomeAws)
    let deniedHomeConfig = probeDeniedRead(path: manifest.deniedHomeConfig)
    let deniedRuntimeSentinel = probeDeniedRead(path: manifest.deniedRuntimeSentinel)
    let deniedProjectsSentinel = probeDeniedRead(path: manifest.deniedProjectsSentinel)
    let deniedSymlinkRel = probeDeniedRead(path: manifest.deniedSymlinkEscapeRel)
    let deniedSymlinkAbs = probeDeniedRead(path: manifest.deniedSymlinkEscapeAbs)
    let deniedAbsolutePath = probeDeniedRead(path: manifest.deniedAbsolutePath)
    let deniedWriteSibling = probeDeniedWrite(path: manifest.deniedWriteSibling)
    let deniedWriteParent = probeDeniedWrite(path: manifest.deniedWriteParent)
    let deniedWriteHome = probeDeniedWrite(path: manifest.deniedWriteHome)

    phaseMap["\(phasePrefix)_ALLOWED_READ"] = allowedRead.status
    phaseMap["\(phasePrefix)_ALLOWED_WRITE"] = allowedWrite.status
    phaseMap["\(phasePrefix)_DENIED_SIBLING_READ"] = deniedSibling.status
    phaseMap["\(phasePrefix)_DENIED_PARENT_READ"] = deniedParent.status
    phaseMap["\(phasePrefix)_DENIED_HOME_SSH"] = deniedHomeSsh.status
    phaseMap["\(phasePrefix)_DENIED_HOME_AWS"] = deniedHomeAws.status
    phaseMap["\(phasePrefix)_DENIED_HOME_CONFIG"] = deniedHomeConfig.status
    phaseMap["\(phasePrefix)_DENIED_RUNTIME_SENTINEL"] = deniedRuntimeSentinel.status
    phaseMap["\(phasePrefix)_DENIED_PROJECTS_SENTINEL"] = deniedProjectsSentinel.status
    phaseMap["\(phasePrefix)_DENIED_SYMLINK_ESCAPE_REL"] = deniedSymlinkRel.status
    phaseMap["\(phasePrefix)_DENIED_SYMLINK_ESCAPE_ABS"] = deniedSymlinkAbs.status
    phaseMap["\(phasePrefix)_DENIED_ABSOLUTE_PATH"] = deniedAbsolutePath.status
    phaseMap["\(phasePrefix)_DENIED_WRITE_SIBLING"] = deniedWriteSibling.status
    phaseMap["\(phasePrefix)_DENIED_WRITE_PARENT"] = deniedWriteParent.status
    phaseMap["\(phasePrefix)_DENIED_WRITE_HOME"] = deniedWriteHome.status

    let netRes = probeNetworkConnect(port: manifest.tcpPort)
    if netRes.status == "PASS" {
        phaseMap["\(phasePrefix)_NETWORK_ACCESS"] = "DENIED"
        phaseMap["\(phasePrefix)_NETWORK_GATE"] = "PASS"
    } else if netRes.status == "FAIL" {
        phaseMap["\(phasePrefix)_NETWORK_ACCESS"] = "ALLOWED"
        phaseMap["\(phasePrefix)_NETWORK_GATE"] = "FAIL"
    } else {
        phaseMap["\(phasePrefix)_NETWORK_ACCESS"] = "UNKNOWN"
        phaseMap["\(phasePrefix)_NETWORK_GATE"] = "INCONCLUSIVE"
    }

    let childProc = Process()
    childProc.executableURL = URL(fileURLWithPath: manifest.helperPath)
    childProc.arguments = [
        "--mode", "child",
        "--probe-allowed", manifest.allowedRead,
        "--probe-sentinel", manifest.deniedSiblingRead
    ]
    let pipe = Pipe()
    childProc.standardOutput = pipe
    do {
        try childProc.run()
        childProc.waitUntilExit()
        let childData = pipe.fileHandleForReading.readDataToEndOfFile()
        if let childRes = try? JSONDecoder().decode(ChildProbeResult.self, from: childData) {
            phaseMap["\(phasePrefix)_CHILD_ALLOWED_READ"] = childRes.childAllowedRead
            phaseMap["\(phasePrefix)_CHILD_DENIED_SENTINEL_READ"] = childRes.childDeniedSentinelRead
            phaseMap["\(phasePrefix)_CHILD_CONTAINMENT"] = childRes.childInheritsContainment
        } else {
            phaseMap["\(phasePrefix)_CHILD_ALLOWED_READ"] = "FAIL"
            phaseMap["\(phasePrefix)_CHILD_DENIED_SENTINEL_READ"] = "FAIL"
            phaseMap["\(phasePrefix)_CHILD_CONTAINMENT"] = "FAIL"
        }
    } catch {
        phaseMap["\(phasePrefix)_CHILD_ALLOWED_READ"] = "FAIL"
        phaseMap["\(phasePrefix)_CHILD_DENIED_SENTINEL_READ"] = "FAIL"
        phaseMap["\(phasePrefix)_CHILD_CONTAINMENT"] = "FAIL"
    }

    let allPass = (allowedRead.status == "PASS") &&
                  (allowedWrite.status == "PASS") &&
                  (deniedSibling.status == "PASS") &&
                  (deniedParent.status == "PASS") &&
                  (deniedHomeSsh.status == "PASS") &&
                  (deniedHomeAws.status == "PASS") &&
                  (deniedHomeConfig.status == "PASS") &&
                  (deniedRuntimeSentinel.status == "PASS") &&
                  (deniedProjectsSentinel.status == "PASS") &&
                  (deniedSymlinkRel.status == "PASS") &&
                  (deniedSymlinkAbs.status == "PASS") &&
                  (deniedAbsolutePath.status == "PASS") &&
                  (deniedWriteSibling.status == "PASS") &&
                  (deniedWriteParent.status == "PASS") &&
                  (deniedWriteHome.status == "PASS") &&
                  (phaseMap["\(phasePrefix)_NETWORK_GATE"] as? String == "PASS") &&
                  (phaseMap["\(phasePrefix)_CHILD_CONTAINMENT"] as? String == "PASS")

    return (phaseMap, allPass)
}

final class ConsoleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var totalBytesSeen: Int = 0
    private var didTruncate = false
    let limit: Int = 4194304 // 4 MiB

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
    var totalBytes: Int { lock.lock(); defer { lock.unlock() }; return totalBytesSeen }
}

final class InlineParser: @unchecked Sendable {
    private let lock = NSLock()
    private var carry = ""
    private(set) var guestFields: [String: String] = [:]
    private(set) var guestInitStarted = false
    private(set) var guestDoneSeen = false

    func feed(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let text = String(data: chunk, encoding: .utf8) ?? String(data: chunk, encoding: .isoLatin1) else { return }
        let combined = carry + text
        let rawLines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        if combined.hasSuffix("\n") {
            carry = ""
            for line in rawLines { processLine(String(line)) }
        } else {
            carry = String(rawLines.last ?? "")
            for line in rawLines.dropLast() { processLine(String(line)) }
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !carry.isEmpty {
            processLine(carry)
            carry = ""
        }
    }

    private func processLine(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        if trimmed.contains("STAGE0D_GUEST_INIT_STARTED=YES") {
            guestInitStarted = true
        }
        if trimmed.contains("STAGE0D_GUEST_DONE=YES") {
            guestDoneSeen = true
        }
        if let eqIdx = trimmed.firstIndex(of: "=") {
            let key = String(trimmed[..<eqIdx])
            let val = String(trimmed[trimmed.index(after: eqIdx)...])
            guestFields[key] = val
        }
    }
}

func runTestMode(manifestPath: String) {
    guard let manifestData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
          let manifest = try? JSONDecoder().decode(ProbeManifest.self, from: manifestData) else {
        fputs("ERROR: failed to read manifest from \(manifestPath)\n", stderr)
        exit(2)
    }

    var report: [String: Any] = [:]

    // ----------------- Phase 1: Pre-VM Host Containment -----------------
    let (phase1Map, phase1Pass) = runHostContainmentProbes(manifest: manifest, phasePrefix: "PRE_VM")
    for (k, v) in phase1Map { report[k] = v }
    report["HOST_CONTAINMENT_PRE_VM"] = phase1Pass ? "PASS" : "FAIL"

    // ----------------- Phase 2: Virtualization + Guest Isolation -----------------
    var vmConfigValidate = "UNKNOWN"
    var vmStart = "UNKNOWN"
    var vmRunning = "UNKNOWN"
    var vmStop = "UNKNOWN"
    var vmFinalState = "UNKNOWN"
    var sandboxDenialEvidence = "NONE"
    var failedOperation = "NONE"
    var failedServiceOrPath = "NONE"
    var blockReason = "NONE"

    let consoleCapture = ConsoleCapture()
    let inlineParser = InlineParser()

    if !VZVirtualMachine.isSupported {
        vmConfigValidate = "FAIL"
        vmStart = "BLOCKED"
        blockReason = "VZ_NOT_SUPPORTED_ON_HARDWARE"
        report["VM_CONFIG_VALIDATE"] = vmConfigValidate
        report["VM_START"] = vmStart
        report["BLOCK_REASON"] = blockReason
    } else {
        do {
            let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: manifest.kernelPath))
            bootLoader.commandLine = "console=hvc0 rdinit=/stage0d-init"
            bootLoader.initialRamdiskURL = URL(fileURLWithPath: manifest.initrdPath)

            let vmConfig = VZVirtualMachineConfiguration()
            vmConfig.bootLoader = bootLoader
            vmConfig.cpuCount = 2
            vmConfig.memorySize = 512 * 1024 * 1024 // 512 MiB

            // Serial console
            let consolePipe = Pipe()
            let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
            serialPort.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: FileHandle.nullDevice,
                fileHandleForWriting: consolePipe.fileHandleForWriting
            )
            vmConfig.serialPorts = [serialPort]

            // VirtioFS share (allowed/share strictly)
            let shareDir = VZSharedDirectory(url: URL(fileURLWithPath: manifest.sharePath), readOnly: false)
            let singleShare = VZSingleDirectoryShare(directory: shareDir)
            let fsDev = VZVirtioFileSystemDeviceConfiguration(tag: manifest.virtiofsTag)
            fsDev.share = singleShare
            vmConfig.directorySharingDevices = [fsDev]

            // Strict: NO network device
            vmConfig.networkDevices = []
            report["VM_NETWORK_DEVICE_COUNT"] = 0

            try vmConfig.validate()
            vmConfigValidate = "PASS"

            let vm = VZVirtualMachine(configuration: vmConfig)

            // Start draining serial pipe asynchronously
            let readHandle = consolePipe.fileHandleForReading
            let group = DispatchGroup()
            group.enter()

            readHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    readHandle.readabilityHandler = nil
                    group.leave()
                } else {
                    consoleCapture.append(chunk)
                    inlineParser.feed(chunk)
                }
            }

            // Start VM
            let startSem = DispatchSemaphore(value: 0)
            var startError: Error? = nil

            vm.start { result in
                switch result {
                case .success:
                    break
                case .failure(let error):
                    startError = error
                }
                startSem.signal()
            }

            _ = startSem.wait(timeout: .now() + 10.0)

            if let err = startError {
                vmStart = "BLOCKED"
                blockReason = "PROFILE_TOO_NARROW"
                sandboxDenialEvidence = "VZVirtualMachine.start failed: \(err.localizedDescription)"
                failedOperation = "vm.start"
                failedServiceOrPath = "Virtualization.framework"
            } else if vm.state == .running {
                vmStart = "PASS"
                vmRunning = "PASS"

                // Wait for guest completion marker STAGE0D_GUEST_DONE=YES
                let startWait = Date()
                while Date().timeIntervalSince(startWait) < 45.0 {
                    if inlineParser.guestDoneSeen { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }

                // Stop VM
                let stopSem = DispatchSemaphore(value: 0)
                var stopError: Error? = nil
                vm.stop { err in
                    stopError = err
                    stopSem.signal()
                }
                _ = stopSem.wait(timeout: .now() + 5.0)

                if stopError == nil && vm.state == .stopped {
                    vmStop = "PASS"
                    vmFinalState = "stopped"
                } else {
                    vmStop = "FAIL"
                    vmFinalState = "\(vm.state.rawValue)"
                }
            } else {
                vmStart = "BLOCKED"
                blockReason = "PROFILE_TOO_NARROW"
                sandboxDenialEvidence = "VM state did not transition to running (state=\(vm.state.rawValue))"
                failedOperation = "vm.start_state_transition"
                failedServiceOrPath = "Virtualization.framework"
            }

            readHandle.readabilityHandler = nil
            try? consolePipe.fileHandleForWriting.close()
            inlineParser.flush()

        } catch {
            vmConfigValidate = "FAIL"
            vmStart = "BLOCKED"
            blockReason = "PROFILE_TOO_NARROW"
            sandboxDenialEvidence = "Virtualization configuration or init threw: \(error.localizedDescription)"
            failedOperation = "vmConfig.validate_or_construct"
            failedServiceOrPath = "com.apple.security.virtualization"
        }
    }

    report["VM_CONFIG_VALIDATE"] = vmConfigValidate
    report["VM_START"] = vmStart
    report["VM_RUNNING"] = vmRunning
    report["VM_STOP"] = vmStop
    report["VM_FINAL_STATE"] = vmFinalState
    report["SANDBOX_DENIAL_EVIDENCE"] = sandboxDenialEvidence
    report["FAILED_OPERATION"] = failedOperation
    report["FAILED_SERVICE_OR_PATH"] = failedServiceOrPath

    // Parse guest fields
    let guestFields = inlineParser.guestFields
    let virtiofsMount = guestFields["VIRTIOFS_MOUNT"] ?? "NOT_RUN"
    let guestHostRead = guestFields["GUEST_HOST_TO_GUEST_READ"] ?? "NOT_RUN"
    let guestHostWrite = guestFields["GUEST_GUEST_TO_HOST_WRITE"] ?? "NOT_RUN"
    let guestDotdot = guestFields["GUEST_DOTDOT_ESCAPE"] ?? "NOT_RUN"
    let guestSymlinkRel = guestFields["GUEST_SYMLINK_ESCAPE_REL"] ?? "NOT_RUN"
    let guestSymlinkAbs = guestFields["GUEST_SYMLINK_ESCAPE_ABS"] ?? "NOT_RUN"
    let guestAbsEscape = guestFields["GUEST_ABSOLUTE_PATH_ESCAPE"] ?? "NOT_RUN"
    let guestHostHome = guestFields["GUEST_HOST_HOME_EXPOSED"] ?? "NOT_RUN"
    let guestVirtioNet = guestFields["GUEST_HAS_VIRTIO_NET"] ?? "NOT_RUN"

    report["VIRTIOFS_MOUNT"] = virtiofsMount
    report["GUEST_HOST_TO_GUEST_READ"] = guestHostRead
    report["GUEST_GUEST_TO_HOST_WRITE"] = guestHostWrite
    report["GUEST_DOTDOT_ESCAPE"] = guestDotdot
    report["GUEST_SYMLINK_ESCAPE_REL"] = guestSymlinkRel
    report["GUEST_SYMLINK_ESCAPE_ABS"] = guestSymlinkAbs
    report["GUEST_ABSOLUTE_PATH_ESCAPE"] = guestAbsEscape
    report["GUEST_HOST_HOME_EXPOSED"] = guestHostHome
    report["GUEST_HAS_VIRTIO_NET"] = guestVirtioNet

    let guestPass = (virtiofsMount == "PASS") &&
                    (guestHostRead == "PASS") &&
                    (guestHostWrite == "PASS") &&
                    (guestDotdot == "PASS") &&
                    (guestSymlinkRel == "PASS") &&
                    (guestSymlinkAbs == "PASS") &&
                    (guestAbsEscape == "PASS") &&
                    (guestHostHome == "NO") &&
                    (guestVirtioNet == "NO")

    report["VIRTIOFS_GUEST_ISOLATION"] = guestPass ? "PASS" : (vmStart == "PASS" ? "FAIL" : "NOT_RUN")
    report["VIRTUALIZATION_VM_LIFECYCLE"] = (vmStart == "PASS" && vmRunning == "PASS" && vmStop == "PASS" && vmFinalState == "stopped") ? "PASS" : (vmStart == "BLOCKED" ? "NOT_RUN" : "FAIL")

    // ----------------- Phase 3: Post-VM Host Containment -----------------
    let (phase3Map, phase3Pass) = runHostContainmentProbes(manifest: manifest, phasePrefix: "POST_VM")
    for (k, v) in phase3Map { report[k] = v }
    report["HOST_CONTAINMENT_POST_VM"] = phase3Pass ? "PASS" : "FAIL"

    // ----------------- Delta Gate -----------------
    var deltaPass = false
    if phase1Pass && phase3Pass {
        var allMatch = true
        let probeKeys = [
            "ALLOWED_READ", "ALLOWED_WRITE",
            "DENIED_SIBLING_READ", "DENIED_PARENT_READ",
            "DENIED_HOME_SSH", "DENIED_HOME_AWS", "DENIED_HOME_CONFIG",
            "DENIED_RUNTIME_SENTINEL", "DENIED_PROJECTS_SENTINEL",
            "DENIED_SYMLINK_ESCAPE_REL", "DENIED_SYMLINK_ESCAPE_ABS",
            "DENIED_ABSOLUTE_PATH",
            "DENIED_WRITE_SIBLING", "DENIED_WRITE_PARENT", "DENIED_WRITE_HOME",
            "NETWORK_ACCESS", "NETWORK_GATE",
            "CHILD_ALLOWED_READ", "CHILD_DENIED_SENTINEL_READ", "CHILD_CONTAINMENT"
        ]
        for key in probeKeys {
            let preVal = phase1Map["PRE_VM_\(key)"] as? String ?? "UNKNOWN"
            let postVal = phase3Map["POST_VM_\(key)"] as? String ?? "UNKNOWN"
            if preVal != postVal || (key.contains("DENIED") && preVal != "PASS" && preVal != "DENIED") {
                allMatch = false
                break
            }
        }
        deltaPass = allMatch
    }
    report["HOST_CONTAINMENT_DELTA"] = deltaPass ? "PASS" : "FAIL"

    // ----------------- Overall Stage0D Result -----------------
    if vmStart == "BLOCKED" {
        report["STAGE0D_RESULT"] = "BLOCKED"
        report["BLOCK_REASON"] = blockReason
    } else if phase1Pass && guestPass && phase3Pass && deltaPass && (report["VIRTUALIZATION_VM_LIFECYCLE"] as? String == "PASS") {
        report["STAGE0D_RESULT"] = "PASS"
        report["BLOCK_REASON"] = "NONE"
    } else {
        report["STAGE0D_RESULT"] = "FAIL"
        report["BLOCK_REASON"] = (blockReason != "NONE") ? blockReason : "CONTAINMENT_OR_ISOLATION_FAILED"
    }

    report["FRAMEWORK_WORKER_TRUST_BOUNDARY"] = "TRUSTED_OS_SERVICE_OUTSIDE_HELPER_SEATBELT"

    if let jsonData = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]),
       let jsonStr = String(data: jsonData, encoding: .utf8) {
        print(jsonStr)
    }
}

func runChildMode(args: [String]) {
    var probeAllowed = ""
    var probeSentinel = ""
    var i = 0
    while i < args.count {
        if args[i] == "--probe-allowed" && i + 1 < args.count {
            probeAllowed = args[i + 1]
            i += 2
        } else if args[i] == "--probe-sentinel" && i + 1 < args.count {
            probeSentinel = args[i + 1]
            i += 2
        } else {
            i += 1
        }
    }

    let allowedRes = probeAllowedRead(path: probeAllowed)
    let sentinelRes = probeDeniedRead(path: probeSentinel)

    let inherits = (allowedRes.status == "PASS" && sentinelRes.status == "PASS") ? "PASS" : "FAIL"
    let childRes = ChildProbeResult(
        childAllowedRead: allowedRes.status,
        childDeniedSentinelRead: sentinelRes.status,
        childInheritsContainment: inherits
    )
    if let data = try? JSONEncoder().encode(childRes), let jsonStr = String(data: data, encoding: .utf8) {
        print(jsonStr)
    }
}

func runValidateMode(args: [String]) {
    var kernel = ""
    var initrd = ""
    var share = ""
    var i = 0
    while i < args.count {
        if args[i] == "--kernel" && i + 1 < args.count {
            kernel = args[i + 1]; i += 2
        } else if args[i] == "--initrd" && i + 1 < args.count {
            initrd = args[i + 1]; i += 2
        } else if args[i] == "--share" && i + 1 < args.count {
            share = args[i + 1]; i += 2
        } else {
            i += 1
        }
    }

    let supported = VZVirtualMachine.isSupported
    let kExists = FileManager.default.fileExists(atPath: kernel)
    let iExists = FileManager.default.fileExists(atPath: initrd)
    let sExists = FileManager.default.fileExists(atPath: share)

    var ok = supported && kExists && iExists
    if !share.isEmpty { ok = ok && sExists }

    let out: [String: Any] = [
        "stage": "validate",
        "isSupported": supported,
        "kernelPresent": kExists,
        "initrdPresent": iExists,
        "sharePresent": sExists,
        "ok": ok
    ]
    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func main() {
    let args = CommandLine.arguments
    var mode = "test"
    var manifestPath = ""

    var i = 1
    while i < args.count {
        if args[i] == "--mode" && i + 1 < args.count {
            mode = args[i + 1]
            i += 2
        } else if args[i] == "--manifest" && i + 1 < args.count {
            manifestPath = args[i + 1]
            i += 2
        } else {
            i += 1
        }
    }

    if mode == "child" {
        runChildMode(args: Array(args.dropFirst()))
    } else if mode == "validate" {
        runValidateMode(args: Array(args.dropFirst()))
    } else {
        if manifestPath.isEmpty {
            fputs("Usage: stage0d-vz-tool --mode test --manifest <probes.json>\n", stderr)
            exit(2)
        }
        runTestMode(manifestPath: manifestPath)
    }
}

main()
