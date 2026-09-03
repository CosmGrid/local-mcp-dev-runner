import Foundation
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
    let payload = "STAGE0C_WRITE_TEST_\(arc4random())\n"
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

    // Verify readback
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

    // Non-blocking connect with timeout
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
        let pollRc = poll(&pfd, 1, 500) // 500ms timeout
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

func runTestMode(manifestPath: String) {
    guard let manifestData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
          let manifest = try? JSONDecoder().decode(ProbeManifest.self, from: manifestData) else {
        fputs("ERROR: failed to read manifest from \(manifestPath)\n", stderr)
        exit(2)
    }

    var report: [String: Any] = [:]

    // 1. Filesystem probes
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

    report["HELPER_ALLOWED_READ"] = allowedRead.status
    report["HELPER_ALLOWED_WRITE"] = allowedWrite.status
    report["HELPER_DENIED_SIBLING_READ"] = deniedSibling.status
    report["HELPER_DENIED_PARENT_READ"] = deniedParent.status
    report["HELPER_DENIED_HOME_SSH"] = deniedHomeSsh.status
    report["HELPER_DENIED_HOME_AWS"] = deniedHomeAws.status
    report["HELPER_DENIED_HOME_CONFIG"] = deniedHomeConfig.status
    report["HELPER_DENIED_RUNTIME_SENTINEL"] = deniedRuntimeSentinel.status
    report["HELPER_DENIED_PROJECTS_SENTINEL"] = deniedProjectsSentinel.status
    report["HELPER_DENIED_SYMLINK_ESCAPE_REL"] = deniedSymlinkRel.status
    report["HELPER_DENIED_SYMLINK_ESCAPE_ABS"] = deniedSymlinkAbs.status
    report["HELPER_DENIED_ABSOLUTE_PATH"] = deniedAbsolutePath.status
    report["HELPER_DENIED_WRITE_SIBLING"] = deniedWriteSibling.status
    report["HELPER_DENIED_WRITE_PARENT"] = deniedWriteParent.status
    report["HELPER_DENIED_WRITE_HOME"] = deniedWriteHome.status

    // 2. Network probe
    let netRes = probeNetworkConnect(port: manifest.tcpPort)
    if netRes.status == "PASS" {
        report["SANDBOXED_NETWORK_CONNECT"] = "DENIED"
        report["HELPER_NETWORK_ACCESS"] = "DENIED"
        report["NETWORK_GATE"] = "PASS"
    } else if netRes.status == "FAIL" {
        report["SANDBOXED_NETWORK_CONNECT"] = "CONNECTED"
        report["HELPER_NETWORK_ACCESS"] = "ALLOWED"
        report["NETWORK_GATE"] = "FAIL"
    } else {
        report["SANDBOXED_NETWORK_CONNECT"] = "INCONCLUSIVE"
        report["HELPER_NETWORK_ACCESS"] = "UNKNOWN"
        report["NETWORK_GATE"] = "INCONCLUSIVE"
    }

    // 3. Child inheritance probe
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
            report["CHILD_ALLOWED_READ"] = childRes.childAllowedRead
            report["CHILD_DENIED_SENTINEL_READ"] = childRes.childDeniedSentinelRead
            report["HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT"] = childRes.childInheritsContainment
        } else {
            report["CHILD_ALLOWED_READ"] = "FAIL"
            report["CHILD_DENIED_SENTINEL_READ"] = "FAIL"
            report["HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT"] = "FAIL"
        }
    } catch {
        report["CHILD_ALLOWED_READ"] = "FAIL"
        report["CHILD_DENIED_SENTINEL_READ"] = "FAIL"
        report["HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT"] = "FAIL"
    }

    if let jsonData = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]),
       let jsonStr = String(data: jsonData, encoding: .utf8) {
        print(jsonStr)
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
    } else {
        if manifestPath.isEmpty {
            fputs("Usage: p35-stage0c-helper --mode test --manifest <probes.json>\n", stderr)
            exit(2)
        }
        runTestMode(manifestPath: manifestPath)
    }
}

main()
