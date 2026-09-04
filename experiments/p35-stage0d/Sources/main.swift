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
    let emitMarker = (phasePrefix == "PRE_VM")

    if emitMarker { fputs("PHASE1_ALLOWED_READ_BEGIN\n", stdout); fflush(stdout) }
    let allowedRead = probeAllowedRead(path: manifest.allowedRead)
    if emitMarker { fputs("PHASE1_ALLOWED_READ_END\n", stdout); fflush(stdout) }

    if emitMarker { fputs("PHASE1_ALLOWED_WRITE_BEGIN\n", stdout); fflush(stdout) }
    let allowedWrite = probeAllowedWrite(path: manifest.allowedWriteTarget)
    if emitMarker { fputs("PHASE1_ALLOWED_WRITE_END\n", stdout); fflush(stdout) }

    if emitMarker { fputs("PHASE1_SIBLING_READ_BEGIN\n", stdout); fflush(stdout) }
    let deniedSibling = probeDeniedRead(path: manifest.deniedSiblingRead)
    let deniedParent = probeDeniedRead(path: manifest.deniedParentRead)
    if emitMarker { fputs("PHASE1_SIBLING_READ_END\n", stdout); fflush(stdout) }

    if emitMarker { fputs("PHASE1_FAKE_HOME_BEGIN\n", stdout); fflush(stdout) }
    let deniedHomeSsh = probeDeniedRead(path: manifest.deniedHomeSsh)
    let deniedHomeAws = probeDeniedRead(path: manifest.deniedHomeAws)
    let deniedHomeConfig = probeDeniedRead(path: manifest.deniedHomeConfig)
    let deniedRuntimeSentinel = probeDeniedRead(path: manifest.deniedRuntimeSentinel)
    let deniedProjectsSentinel = probeDeniedRead(path: manifest.deniedProjectsSentinel)
    if emitMarker { fputs("PHASE1_FAKE_HOME_END\n", stdout); fflush(stdout) }

    if emitMarker { fputs("PHASE1_SYMLINK_BEGIN\n", stdout); fflush(stdout) }
    let deniedSymlinkRel = probeDeniedRead(path: manifest.deniedSymlinkEscapeRel)
    let deniedSymlinkAbs = probeDeniedRead(path: manifest.deniedSymlinkEscapeAbs)
    if emitMarker { fputs("PHASE1_SYMLINK_END\n", stdout); fflush(stdout) }

    if emitMarker { fputs("PHASE1_ABSOLUTE_PATH_BEGIN\n", stdout); fflush(stdout) }
    let deniedAbsolutePath = probeDeniedRead(path: manifest.deniedAbsolutePath)
    if emitMarker { fputs("PHASE1_ABSOLUTE_PATH_END\n", stdout); fflush(stdout) }

    if emitMarker { fputs("PHASE1_DENIED_WRITE_BEGIN\n", stdout); fflush(stdout) }
    let deniedWriteSibling = probeDeniedWrite(path: manifest.deniedWriteSibling)
    let deniedWriteParent = probeDeniedWrite(path: manifest.deniedWriteParent)
    let deniedWriteHome = probeDeniedWrite(path: manifest.deniedWriteHome)
    if emitMarker { fputs("PHASE1_DENIED_WRITE_END\n", stdout); fflush(stdout) }

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

    if emitMarker { fputs("PHASE1_NETWORK_BEGIN\n", stdout); fflush(stdout) }
    let netRes = probeNetworkConnect(port: manifest.tcpPort)
    if emitMarker { fputs("PHASE1_NETWORK_END\n", stdout); fflush(stdout) }

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

    if emitMarker { fputs("PHASE1_CHILD_BEGIN\n", stdout); fflush(stdout) }
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
        let childExit = childProc.terminationStatus
        if childExit == 0 {
            let childData = pipe.fileHandleForReading.readDataToEndOfFile()
            if let rawOutput = String(data: childData, encoding: .utf8) {
                var decodedRes: ChildProbeResult? = nil
                for line in rawOutput.split(separator: "\n") {
                    let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedLine.hasPrefix("CHILD_PROBE_JSON=") {
                        let jsonPart = String(trimmedLine.dropFirst("CHILD_PROBE_JSON=".count))
                        if let d = jsonPart.data(using: .utf8),
                           let res = try? JSONDecoder().decode(ChildProbeResult.self, from: d) {
                            decodedRes = res
                            break
                        }
                    }
                }
                if decodedRes == nil,
                   let s = rawOutput.range(of: "{"),
                   let e = rawOutput.range(of: "}", options: .backwards) {
                    let sub = String(rawOutput[s.lowerBound...e.upperBound])
                    if let d = sub.data(using: .utf8),
                       let res = try? JSONDecoder().decode(ChildProbeResult.self, from: d) {
                        decodedRes = res
                    }
                }

                if let childRes = decodedRes {
                    phaseMap["\(phasePrefix)_CHILD_ALLOWED_READ"] = childRes.childAllowedRead
                    phaseMap["\(phasePrefix)_CHILD_DENIED_SENTINEL_READ"] = childRes.childDeniedSentinelRead
                    phaseMap["\(phasePrefix)_CHILD_CONTAINMENT"] = childRes.childInheritsContainment
                } else {
                    phaseMap["\(phasePrefix)_CHILD_ALLOWED_READ"] = "FAIL"
                    phaseMap["\(phasePrefix)_CHILD_DENIED_SENTINEL_READ"] = "FAIL"
                    phaseMap["\(phasePrefix)_CHILD_CONTAINMENT"] = "FAIL"
                }
            } else {
                phaseMap["\(phasePrefix)_CHILD_ALLOWED_READ"] = "FAIL"
                phaseMap["\(phasePrefix)_CHILD_DENIED_SENTINEL_READ"] = "FAIL"
                phaseMap["\(phasePrefix)_CHILD_CONTAINMENT"] = "FAIL"
            }
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
    if emitMarker { fputs("PHASE1_CHILD_END\n", stdout); fflush(stdout) }

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
    private var guestFields: [String: String] = [:]
    var allFields: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return guestFields
    }
    private(set) var guestInitStarted = false
    private(set) var guestDoneSeen = false

    func feed(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let text = String(data: chunk, encoding: .utf8) ?? String(data: chunk, encoding: .isoLatin1) else { return }
        let combined = carry + text
        let normalized = combined.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        if normalized.hasSuffix("\n") {
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
        if trimmed.contains("STAGE0D_GUEST_INIT_STARTED=YES") || trimmed.contains("GUEST_INIT_STARTED=YES") {
            guestInitStarted = true
        }
        if trimmed.contains("STAGE0D_GUEST_DONE=YES") {
            guestDoneSeen = true
        }
        if let eqIdx = trimmed.firstIndex(of: "=") {
            let rawKey = String(trimmed[..<eqIdx])
            let rawVal = String(trimmed[trimmed.index(after: eqIdx)...])
            let cleanKey = rawKey.filter { $0.isLetter || $0.isNumber || $0 == "_" }
            let cleanVal = rawVal.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanKey.isEmpty {
                guestFields[cleanKey] = cleanVal
            }
        }
    }
}

final class VMContext {
    var consoleReadFD: Int32 = -1
    var consoleWriteFD: Int32 = -1
    var fromGuestReadHandle: FileHandle? = nil
    var fromGuestWriteHandle: FileHandle? = nil
    var serialAttachment: VZFileHandleSerialPortAttachment? = nil
    var vmConfig: VZVirtualMachineConfiguration? = nil
    var vm: VZVirtualMachine? = nil

    // Full object lifecycle retention
    var bootLoader: VZLinuxBootLoader? = nil
    var consoleDevice: VZVirtioConsoleDeviceConfiguration? = nil
    var consolePort: VZVirtioConsolePortConfiguration? = nil
    var sharedDirectory: VZSharedDirectory? = nil
    var singleDirectoryShare: VZSingleDirectoryShare? = nil
    var fileSystemDevice: VZVirtioFileSystemDeviceConfiguration? = nil
    var kernelURL: URL? = nil
    var initrdURL: URL? = nil
    var shareURL: URL? = nil

    let vmQueueKey = DispatchSpecificKey<String>()
    let vmQueueLabel = "com.localmcpdevrunner.stage0d.vz"
    let vmQueue: DispatchQueue

    init() {
        let q = DispatchQueue(label: vmQueueLabel, qos: .userInitiated)
        q.setSpecific(key: vmQueueKey, value: vmQueueLabel)
        self.vmQueue = q
    }

    deinit {
        if consoleReadFD >= 0 { close(consoleReadFD) }
        if consoleWriteFD >= 0 { close(consoleWriteFD) }
    }
}

func startConsoleReader(readFD: Int32, capture: ConsoleCapture, parser: InlineParser) -> DispatchSourceRead {
    _ = fcntl(readFD, F_SETFL, O_NONBLOCK)
    let source = DispatchSource.makeReadSource(
        fileDescriptor: readFD,
        queue: DispatchQueue.global(qos: .utility)
    )
    source.setEventHandler {
        var buf = [UInt8](repeating: 0, count: 8192)
        let chunkSize = buf.count
        while true {
            let n = buf.withUnsafeMutableBytes { read(readFD, $0.baseAddress, chunkSize) }
            if n > 0 {
                let chunk = Data(buf[0..<n])
                capture.append(chunk)
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

func buildVMConfiguration(manifest: ProbeManifest, ctx: VMContext) throws -> VZVirtualMachineConfiguration {
    fputs("VZ_BOOTLOADER_BEGIN\n", stdout); fflush(stdout)
    let kURL = URL(fileURLWithPath: manifest.kernelPath)
    let iURL = URL(fileURLWithPath: manifest.initrdPath)
    ctx.kernelURL = kURL
    ctx.initrdURL = iURL

    let bootLoader = VZLinuxBootLoader(kernelURL: kURL)
    bootLoader.commandLine = "console=hvc0 rdinit=/stage0d-init"
    bootLoader.initialRamdiskURL = iURL
    ctx.bootLoader = bootLoader
    fputs("VZ_BOOTLOADER_END\n", stdout); fflush(stdout)

    fputs("VZ_SERIAL_PIPE_BEGIN\n", stdout); fflush(stdout)
    var pipeFDs: [Int32] = [-1, -1]
    guard pipe(&pipeFDs) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
    ctx.consoleReadFD = pipeFDs[0]
    ctx.consoleWriteFD = pipeFDs[1]
    let fromGuest = FileHandle(fileDescriptor: ctx.consoleWriteFD, closeOnDealloc: false)
    ctx.fromGuestWriteHandle = fromGuest
    fputs("VZ_SERIAL_PIPE_END\n", stdout); fflush(stdout)

    fputs("VZ_SERIAL_ATTACHMENT_BEGIN\n", stdout); fflush(stdout)
    let serialAttachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: nil,
        fileHandleForWriting: fromGuest
    )
    ctx.serialAttachment = serialAttachment
    fputs("VZ_SERIAL_ATTACHMENT_END\n", stdout); fflush(stdout)

    fputs("VZ_SERIAL_DEVICE_BEGIN\n", stdout); fflush(stdout)
    let console = VZVirtioConsoleDeviceConfiguration()
    let consolePort = VZVirtioConsolePortConfiguration()
    consolePort.isConsole = true
    consolePort.attachment = serialAttachment
    console.ports[0] = consolePort
    ctx.consoleDevice = console
    ctx.consolePort = consolePort
    fputs("VZ_SERIAL_DEVICE_END\n", stdout); fflush(stdout)

    fputs("VZ_VIRTIOFS_SHARE_BEGIN\n", stdout); fflush(stdout)
    let sURL = URL(fileURLWithPath: manifest.sharePath)
    ctx.shareURL = sURL
    let shareDir = VZSharedDirectory(url: sURL, readOnly: false)
    let singleShare = VZSingleDirectoryShare(directory: shareDir)
    ctx.sharedDirectory = shareDir
    ctx.singleDirectoryShare = singleShare
    if let items = try? FileManager.default.contentsOfDirectory(atPath: manifest.sharePath) {
        let accR = access(manifest.sharePath, R_OK)
        let accW = access(manifest.sharePath, W_OK)
        let hostReadFile = manifest.sharePath + "/host-read.txt"
        let hostReadAcc = access(hostReadFile, R_OK)
        fputs("HOST_DEBUG_SHARE_PATH=\(manifest.sharePath) accR=\(accR) accW=\(accW) hostReadAcc=\(hostReadAcc) ITEMS=\(items.joined(separator: ","))\n", stderr)
    } else {
        fputs("HOST_DEBUG_SHARE_PATH=\(manifest.sharePath) ITEMS=FAILED\n", stderr)
    }
    fputs("VZ_VIRTIOFS_SHARE_END\n", stdout); fflush(stdout)

    fputs("VZ_VIRTIOFS_DEVICE_BEGIN\n", stdout); fflush(stdout)
    let fsDev = VZVirtioFileSystemDeviceConfiguration(tag: manifest.virtiofsTag)
    fsDev.share = singleShare
    ctx.fileSystemDevice = fsDev
    fputs("VZ_VIRTIOFS_DEVICE_END\n", stdout); fflush(stdout)

    fputs("VZ_CONFIG_OBJECT_BEGIN\n", stdout); fflush(stdout)
    let vmConfig = VZVirtualMachineConfiguration()
    vmConfig.bootLoader = bootLoader
    vmConfig.cpuCount = 2
    vmConfig.memorySize = 512 * 1024 * 1024 // 512 MiB
    vmConfig.consoleDevices = [console]
    vmConfig.directorySharingDevices = [fsDev]
    vmConfig.networkDevices = []
    ctx.vmConfig = vmConfig
    fputs("VZ_CONFIG_OBJECT_END\n", stdout); fflush(stdout)

    fputs("VZ_CONFIG_VALIDATE_BEGIN\n", stdout); fflush(stdout)
    try vmConfig.validate()
    fputs("VZ_CONFIG_VALIDATE_END\n", stdout); fflush(stdout)

    return vmConfig
}

func runVZConfigSmokeMode(manifestPath: String) {
    guard let manifestData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
          let manifest = try? JSONDecoder().decode(ProbeManifest.self, from: manifestData) else {
        fputs("ERROR: failed to read manifest from \(manifestPath)\n", stderr)
        exit(2)
    }
    fputs("STAGE0D_VZ_CONFIG_SMOKE_ENTERED=YES\n", stdout); fflush(stdout)
    let ctx = VMContext()
    do {
        _ = try buildVMConfiguration(manifest: manifest, ctx: ctx)
        print("STAGE0D_VZ_CONFIG_SMOKE_RESULT=PASS")
        exit(0)
    } catch {
        print("STAGE0D_VZ_CONFIG_SMOKE_RESULT=FAIL: \(error)")
        exit(1)
    }
}

func runVMStartSmokeMode(manifestPath: String) {
    guard let manifestData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
          let manifest = try? JSONDecoder().decode(ProbeManifest.self, from: manifestData) else {
        fputs("ERROR: failed to read manifest from \(manifestPath)\n", stderr)
        exit(2)
    }
    fputs("STAGE0D_VM_START_SMOKE_ENTERED=YES\n", stdout); fflush(stdout)
    let vmCtx = VMContext()
    do {
        let vmConfig = try buildVMConfiguration(manifest: manifest, ctx: vmCtx)
        var vm: VZVirtualMachine!
        vmCtx.vmQueue.sync {
            vm = VZVirtualMachine(configuration: vmConfig, queue: vmCtx.vmQueue)
        }
        vmCtx.vm = vm

        let startGroup = DispatchGroup()
        startGroup.enter()
        var startError: Error? = nil
        fputs("STAGE0D_VM_START_ATTEMPTED=YES\n", stdout); fflush(stdout)
        vmCtx.vmQueue.async {
            fputs("STAGE0D_VM_START_CALLED_ON_QUEUE=YES\n", stdout); fflush(stdout)
            vm.start { result in
                switch result {
                case .success:
                    fputs("STAGE0D_VM_START_CALLBACK=SUCCESS\n", stdout); fflush(stdout)
                case .failure(let err):
                    fputs("STAGE0D_VM_START_CALLBACK=FAILURE: \(err.localizedDescription)\n", stdout); fflush(stdout)
                    startError = err
                }
                startGroup.leave()
            }
        }
        startGroup.wait()

        if let err = startError {
            fputs("STAGE0D_VM_START_SMOKE_RESULT=FAIL: \(err.localizedDescription)\n", stderr)
            exit(1)
        }

        var isRunning = false
        for _ in 0..<40 {
            let grp = DispatchGroup(); grp.enter()
            var st: VZVirtualMachine.State = .stopped
            vmCtx.vmQueue.async { st = vm.state; grp.leave() }
            grp.wait()
            if st == .running {
                isRunning = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        if isRunning {
            fputs("STAGE0D_VM_RUNNING=YES\n", stdout); fflush(stdout)
            let stopGroup = DispatchGroup(); stopGroup.enter()
            vmCtx.vmQueue.async {
                fputs("STAGE0D_VM_STOP_CALLED_ON_QUEUE=YES\n", stdout); fflush(stdout)
                vm.stop { _ in stopGroup.leave() }
            }
            stopGroup.wait()

            var finalSt: VZVirtualMachine.State = .stopped
            let fGrp = DispatchGroup(); fGrp.enter()
            vmCtx.vmQueue.async { finalSt = vm.state; fGrp.leave() }
            fGrp.wait()

            print("STAGE0D_VM_START_SMOKE_RESULT=PASS")
            print("FINAL_VM_STATE=\(finalSt.rawValue)")
            exit(0)
        } else {
            fputs("STAGE0D_VM_START_SMOKE_RESULT=FAIL: not running\n", stderr)
            exit(1)
        }
    } catch {
        fputs("STAGE0D_VM_START_SMOKE_RESULT=FAIL: \(error)\n", stderr)
        exit(1)
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
    fputs("STAGE0D_PHASE1_ENTERED=YES\n", stdout); fflush(stdout)
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
        let vmCtx = VMContext()
        do {
            fputs("STAGE0D_VZ_CONFIG_ENTERED=YES\n", stdout); fflush(stdout)
            let vmConfig = try buildVMConfiguration(manifest: manifest, ctx: vmCtx)
            vmConfigValidate = "PASS"

            var vm: VZVirtualMachine!
            vmCtx.vmQueue.sync {
                vm = VZVirtualMachine(configuration: vmConfig, queue: vmCtx.vmQueue)
            }
            vmCtx.vm = vm

            // Start draining serial pipe asynchronously via DispatchSource
            let consoleSource = startConsoleReader(readFD: vmCtx.consoleReadFD, capture: consoleCapture, parser: inlineParser)

            // Start VM on vmCtx.vmQueue
            let startGroup = DispatchGroup()
            startGroup.enter()
            var startError: Error? = nil

            fputs("STAGE0D_VM_START_ATTEMPTED=YES\n", stdout); fflush(stdout)
            vmCtx.vmQueue.async {
                fputs("STAGE0D_VM_START_CALLED_ON_QUEUE=YES\n", stdout); fflush(stdout)
                vm.start { result in
                    switch result {
                    case .success:
                        fputs("STAGE0D_VM_START_CALLBACK=SUCCESS\n", stdout); fflush(stdout)
                    case .failure(let error):
                        fputs("STAGE0D_VM_START_CALLBACK=FAILURE: \(error.localizedDescription)\n", stdout); fflush(stdout)
                        startError = error
                    }
                    startGroup.leave()
                }
            }
            startGroup.wait()

            var isRunning = false
            for _ in 0..<40 {
                let grp = DispatchGroup(); grp.enter()
                var st: VZVirtualMachine.State = .stopped
                vmCtx.vmQueue.async { st = vm.state; grp.leave() }
                grp.wait()
                if st == .running {
                    isRunning = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }

            if let err = startError {
                vmStart = "BLOCKED"
                blockReason = "PROFILE_TOO_NARROW"
                sandboxDenialEvidence = "VZVirtualMachine.start failed: \(err.localizedDescription)"
                failedOperation = "vm.start"
                failedServiceOrPath = "Virtualization.framework"
            } else if isRunning {
                vmStart = "PASS"
                vmRunning = "PASS"

                // Wait for guest completion marker STAGE0D_GUEST_DONE=YES
                var guestDoneSeen = false
                let startWait = Date()
                let waitLimit: TimeInterval = 35.0
                while Date().timeIntervalSince(startWait) < waitLimit {
                    if inlineParser.guestDoneSeen {
                        guestDoneSeen = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }

                // Settle briefly to drain remaining bytes
                Thread.sleep(forTimeInterval: guestDoneSeen ? 0.8 : 0.2)

                // Stop VM on vmQueue
                let stopGroup = DispatchGroup()
                stopGroup.enter()
                var stopError: Error? = nil
                vmCtx.vmQueue.async {
                    fputs("STAGE0D_VM_STOP_CALLED_ON_QUEUE=YES\n", stdout); fflush(stdout)
                    vm.stop { err in
                        stopError = err
                        stopGroup.leave()
                    }
                }
                stopGroup.wait()

                var finalState: VZVirtualMachine.State = .stopped
                let fGrp = DispatchGroup(); fGrp.enter()
                vmCtx.vmQueue.async { finalState = vm.state; fGrp.leave() }
                fGrp.wait()

                if stopError == nil && finalState == .stopped {
                    vmStop = "PASS"
                    vmFinalState = "stopped"
                } else {
                    vmStop = "FAIL"
                    vmFinalState = "\(finalState.rawValue)"
                }
            } else {
                vmStart = "BLOCKED"
                blockReason = "PROFILE_TOO_NARROW"
                var curState: VZVirtualMachine.State = .stopped
                let sGrp = DispatchGroup(); sGrp.enter()
                vmCtx.vmQueue.async { curState = vm.state; sGrp.leave() }
                sGrp.wait()
                sandboxDenialEvidence = "VM state did not transition to running (state=\(curState.rawValue))"
                failedOperation = "vm.start_state_transition"
                failedServiceOrPath = "Virtualization.framework"
            }

            consoleSource.cancel()
            try? vmCtx.fromGuestWriteHandle?.close()
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

    // Parse guest fields from inline parser & share-backed file (dual channel)
    var guestFields = inlineParser.allFields
    fputs("HOST_DEBUG_INLINE_KEYS=\(guestFields.keys.joined(separator: ","))\n", stderr)
    let resultsURL = URL(fileURLWithPath: manifest.sharePath).appendingPathComponent("guest-results.txt")
    if let fileData = try? Data(contentsOf: resultsURL),
       let fileStr = String(data: fileData, encoding: .utf8) {
        let lines = fileStr.split(separator: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let eqIdx = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eqIdx])
                let val = String(trimmed[trimmed.index(after: eqIdx)...])
                guestFields[key] = val
            }
        }
    }

    let completionSeen = (inlineParser.guestDoneSeen || guestFields["STAGE0D_GUEST_DONE"] == "YES")
    report["GUEST_COMPLETION_SEEN"] = completionSeen ? "YES" : "NO"
    report["GUEST_BOOT_TIMEOUT"] = completionSeen ? "NO" : "YES"

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
    report["GUEST_INIT_STARTED"] = guestFields["GUEST_INIT_STARTED"] ?? (inlineParser.guestInitStarted ? "YES" : "NO")
    report["GUEST_EARLY_USERSPACE_READY"] = guestFields["GUEST_EARLY_USERSPACE_READY"] ?? "NOT_RUN"
    report["GUEST_VIRTIOFS_DEVICE_SEEN"] = guestFields["GUEST_VIRTIOFS_DEVICE_SEEN"] ?? "NOT_RUN"
    report["GUEST_VIRTIOFS_MOUNT_ATTEMPTED"] = guestFields["GUEST_VIRTIOFS_MOUNT_ATTEMPTED"] ?? "NOT_RUN"
    report["GUEST_VIRTIOFS_MOUNT_RESULT"] = guestFields["GUEST_VIRTIOFS_MOUNT_RESULT"] ?? (guestFields["VIRTIOFS_MOUNT"] ?? "NOT_RUN")
    report["GUEST_HOST_READ_ATTEMPTED"] = guestFields["GUEST_HOST_READ_ATTEMPTED"] ?? "NOT_RUN"
    report["GUEST_HOST_READ_RESULT"] = guestFields["GUEST_HOST_READ_RESULT"] ?? "NOT_RUN"
    report["GUEST_HOST_WRITE_ATTEMPTED"] = guestFields["GUEST_HOST_WRITE_ATTEMPTED"] ?? "NOT_RUN"
    report["GUEST_HOST_WRITE_RESULT"] = guestFields["GUEST_HOST_WRITE_RESULT"] ?? "NOT_RUN"
    report["GUEST_ESCAPE_PROBES_STARTED"] = guestFields["GUEST_ESCAPE_PROBES_STARTED"] ?? "NOT_RUN"
    report["GUEST_NETWORK_PROBE_STARTED"] = guestFields["GUEST_NETWORK_PROBE_STARTED"] ?? "NOT_RUN"
    report["STAGE0D_GUEST_DONE"] = completionSeen ? "YES" : "NO"

    // Host-side verification of Guest write-back file
    let guestWriteURL = URL(fileURLWithPath: manifest.sharePath).appendingPathComponent("guest-write.txt")
    var hostVerifiedGuestWrite = false
    if let expectedMarker = guestFields["GUEST_WRITE_MARKER"], !expectedMarker.isEmpty,
       let writeContent = try? String(contentsOf: guestWriteURL, encoding: .utf8) {
        if writeContent.contains(expectedMarker) {
            hostVerifiedGuestWrite = true
        }
    }

    let guestPass = (virtiofsMount == "PASS") &&
                    (guestHostRead == "PASS") &&
                    (guestHostWrite == "PASS") &&
                    hostVerifiedGuestWrite &&
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

    let capData = consoleCapture.snapshot()
    let capStr = String(data: capData, encoding: .utf8) ?? String(data: capData, encoding: .isoLatin1) ?? "(no console output)"
    fputs("=== GUEST CONSOLE CAPTURE (\(capData.count) bytes) ===\n\(capStr)\n=== END GUEST CONSOLE CAPTURE ===\n", stderr)
    let lines = capStr.split(separator: "\n")
    let tailLines = lines.suffix(40).joined(separator: "\n")
    report["CONSOLE_LOG_SNIPPET"] = tailLines

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
        print("CHILD_PROBE_JSON=\(jsonStr)")
        fflush(stdout)
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

func runPhase1ControlMode(manifestPath: String) {
    guard let manifestData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
          let manifest = try? JSONDecoder().decode(ProbeManifest.self, from: manifestData) else {
        fputs("ERROR: failed to read manifest from \(manifestPath)\n", stderr)
        exit(2)
    }
    fputs("STAGE0D_PHASE1_CONTROL_ENTERED=YES\n", stdout); fflush(stdout)
    let (phase1Map, _) = runHostContainmentProbes(manifest: manifest, phasePrefix: "PRE_VM")

    let allowedReadOk = (phase1Map["PRE_VM_ALLOWED_READ"] as? String == "PASS")
    let allowedWriteOk = (phase1Map["PRE_VM_ALLOWED_WRITE"] as? String == "PASS")

    var sentinelsExist = true
    let readSentinels = [
        "PRE_VM_DENIED_SIBLING_READ", "PRE_VM_DENIED_PARENT_READ",
        "PRE_VM_DENIED_HOME_SSH", "PRE_VM_DENIED_HOME_AWS", "PRE_VM_DENIED_HOME_CONFIG",
        "PRE_VM_DENIED_RUNTIME_SENTINEL", "PRE_VM_DENIED_PROJECTS_SENTINEL",
        "PRE_VM_DENIED_SYMLINK_ESCAPE_REL", "PRE_VM_DENIED_SYMLINK_ESCAPE_ABS",
        "PRE_VM_DENIED_ABSOLUTE_PATH"
    ]
    for key in readSentinels {
        if let st = phase1Map[key] as? String {
            if st == "INCONCLUSIVE" {
                sentinelsExist = false
                break
            }
        }
    }

    var writesReachable = true
    let writeSentinels = [
        "PRE_VM_DENIED_WRITE_SIBLING", "PRE_VM_DENIED_WRITE_PARENT", "PRE_VM_DENIED_WRITE_HOME"
    ]
    for key in writeSentinels {
        if let st = phase1Map[key] as? String {
            if st == "INCONCLUSIVE" {
                writesReachable = false
                break
            }
        }
    }

    let controlPass = allowedReadOk && allowedWriteOk && sentinelsExist && writesReachable

    var report = phase1Map
    report["EXPECTATION_MODE"] = "UNSANDBOXED_CONTROL"
    report["PHASE1_CONTROL_RESULT"] = controlPass ? "PASS" : "FAIL"
    report["UNSANDBOXED_SENTINELS_EXIST"] = sentinelsExist ? "YES" : "NO"
    report["UNSANDBOXED_WRITES_REACHABLE"] = writesReachable ? "YES" : "NO"

    if let jsonData = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]),
       let jsonStr = String(data: jsonData, encoding: .utf8) {
        print(jsonStr)
    }
    exit(controlPass ? 0 : 1)
}

func runPhase1SmokeMode(manifestPath: String) {
    guard let manifestData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
          let manifest = try? JSONDecoder().decode(ProbeManifest.self, from: manifestData) else {
        fputs("ERROR: failed to read manifest from \(manifestPath)\n", stderr)
        exit(2)
    }
    fputs("STAGE0D_PHASE1_ENTERED=YES\n", stdout); fflush(stdout)
    let (phase1Map, phase1Pass) = runHostContainmentProbes(manifest: manifest, phasePrefix: "PRE_VM")
    var report = phase1Map
    report["HOST_CONTAINMENT_PRE_VM"] = phase1Pass ? "PASS" : "FAIL"
    report["STAGE0D_PHASE1_SMOKE_RESULT"] = phase1Pass ? "PASS" : "FAIL"
    if let jsonData = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]),
       let jsonStr = String(data: jsonData, encoding: .utf8) {
        print(jsonStr)
    }
    exit(phase1Pass ? 0 : 1)
}

func main() {
    fputs("STAGE0D_MAIN_ENTERED=YES\n", stdout); fflush(stdout)
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
    fputs("STAGE0D_ARGS_PARSED=YES\n", stdout); fflush(stdout)

    if mode == "startup-smoke" {
        fputs("STAGE0D_STARTUP_SMOKE_ENTERED=YES\n", stdout)
        print("STAGE0D_HELPER_PID=\(getpid())")
        print("STAGE0D_HELPER_MAIN_ENTERED=YES")
        fflush(stdout)
        exit(0)
    } else if mode == "phase1-control" {
        if manifestPath.isEmpty {
            fputs("Usage: stage0d-vz-tool --mode phase1-control --manifest <probes.json>\n", stderr)
            exit(2)
        }
        runPhase1ControlMode(manifestPath: manifestPath)
    } else if mode == "phase1-smoke" {
        if manifestPath.isEmpty {
            fputs("Usage: stage0d-vz-tool --mode phase1-smoke --manifest <probes.json>\n", stderr)
            exit(2)
        }
        runPhase1SmokeMode(manifestPath: manifestPath)
    } else if mode == "vz-config-smoke" {
        if manifestPath.isEmpty {
            fputs("Usage: stage0d-vz-tool --mode vz-config-smoke --manifest <probes.json>\n", stderr)
            exit(2)
        }
        runVZConfigSmokeMode(manifestPath: manifestPath)
    } else if mode == "vm-start-smoke" {
        if manifestPath.isEmpty {
            fputs("Usage: stage0d-vz-tool --mode vm-start-smoke --manifest <probes.json>\n", stderr)
            exit(2)
        }
        runVMStartSmokeMode(manifestPath: manifestPath)
    } else if mode == "child" {
        runChildMode(args: Array(args.dropFirst()))
    } else if mode == "validate" {
        runValidateMode(args: Array(args.dropFirst()))
    } else {
        if manifestPath.isEmpty {
            fputs("Usage: stage0d-vz-tool --mode test --manifest <probes.json>\n", stderr)
            exit(2)
        }
        fputs("STAGE0D_TEST_MODE_ENTERED=YES\n", stdout); fflush(stdout)
        runTestMode(manifestPath: manifestPath)
    }
}

main()
