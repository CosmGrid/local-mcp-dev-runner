// Stage 0B VirtioFS Isolation Prototype — minimal VZ helper.
//
// Purpose (ONLY): validate Apple Virtualization.framework VirtioFS directory
//   sharing for the Local MCP Dev Runner worktree-isolation design (P3.5), on
//   this Intel Mac, using a TEMP host directory only:
//     (a) build + validate an x86_64 Linux VM config with ZERO network devices
//         AND a single VirtioFS share tagged "lmdr-stage0b",
//     (b) actually start + stop such a VM, with the share attached,
//     (c) re-use the Stage 0A queue-affinity fix (no SIGILL).
//
// This is a prototype. It deliberately does NOT:
//   - integrate with the Local MCP Dev Runner / server.mjs / run_script,
//   - touch projects.json or the deployed runtime,
//   - mount a real worktree, configure networking, IPC/XPC, warm pools.
//
// Subcommands:
//   validate --kernel <url> --initrd <url> [--cmdline <str>] [--share <url>]
//       Build + validate the config; print JSON. Does NOT start a VM.
//       If --share is given, a VirtioFS device (tag "lmdr-stage0b") is attached.
//   run --kernel <url> --initrd <url> [--cmdline <str>] [--share <url>]
//        [--run-seconds <n>]
//       Build + validate + start the VM (with share if provided), hold, then stop.
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
// VIRTIOFS API (correct form, per Stage 0B task book — DO NOT use the
//   VZSingleDirectoryShare(directory:readOnly:) convenience initializer):
//     let sharedDirectory = VZSharedDirectory(url: allowedDirURL, readOnly: false)
//     let share = VZSingleDirectoryShare(directory: sharedDirectory)
//     let fs = VZVirtioFileSystemDeviceConfiguration(tag: "lmdr-stage0b")
//     fs.share = share
//     config.directorySharingDevices = [fs]

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

// ----- build the x86_64 Linux VM configuration -----
func buildConfig() -> VZVirtualMachineConfiguration {
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

    // One virtio console so the guest's console=hvc0 has a device.
    let console = VZVirtioConsoleDeviceConfiguration()
    let consolePort = VZVirtioConsolePortConfiguration()
    consolePort.isConsole = true
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
    let config = buildConfig()
    var configValid = false
    var validateError: String? = nil
    do {
        try config.validate()
        configValid = true
    } catch {
        validateError = String(describing: error)
    }

    let virtiofsAttached = !config.directorySharingDevices.isEmpty
    let virtiofsTag = virtiofsAttached ? VIRTIOFS_TAG : ""
    let virtiofsShareMode = virtiofsAttached ? "read-write" : ""

    emit([
        "stage": "validate",
        "ok": configValid,
        "isSupported": isSupported,
        "cpuArch": "x86_64",
        "cpuCount": config.cpuCount,
        "memoryBytes": config.memorySize,
        "networkDeviceCount": config.networkDevices.count,
        "virtiofsDevice": virtiofsAttached ? "VZVirtioFileSystemDeviceConfiguration" : "",
        "virtiofsTag": virtiofsTag,
        "virtiofsShareMode": virtiofsShareMode,
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

        let config = buildConfig()
        do { try config.validate() } catch {
            fail("run", "config.validate failed: \(error)")
        }

        var vm: VZVirtualMachine!
        vmQueue.sync {
            vmCreateQueue = (DispatchQueue.getSpecific(key: vmQueueKey) != nil) ? vmQueueLabel : "OTHER"
            vm = VZVirtualMachine(configuration: config, queue: vmQueue)
        }

        let startT = Date()

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

            Thread.sleep(forTimeInterval: Double(runSeconds))

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
        emit([
            "stage": "run",
            "ok": vmStart && vmRunning && vmStop,
            "isSupported": isSupported,
            "cpuArch": "x86_64",
            "networkDeviceCount": config.networkDevices.count,
            "virtiofsDevice": virtiofsAttached ? "VZVirtioFileSystemDeviceConfiguration" : "",
            "virtiofsTag": virtiofsAttached ? VIRTIOFS_TAG : "",
            "virtiofsShareMode": virtiofsAttached ? "read-write" : "",
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
