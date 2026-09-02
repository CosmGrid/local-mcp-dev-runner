// Stage 0A Virtualization Native Prototype — minimal VZ helper.
//
// Purpose (ONLY): prove Virtualization.framework can, on this Intel Mac,
//   (a) report VZVirtualMachine.isSupported,
//   (b) build + validate an x86_64 Linux VM configuration with ZERO network
//       devices, and
//   (c) actually start + stop such a VM.
//
// This is a prototype. It deliberately does NOT:
//   - integrate with the Local MCP Dev Runner / server.mjs / run_script,
//   - touch projects.json or the deployed runtime,
//   - mount a worktree, configure networking, IPC/XPC, warm pools, snapshots.
//
// Subcommands:
//   validate --kernel <url> --initrd <url> [--cmdline <str>]
//       Build + validate the config; print JSON. Does NOT start a VM.
//   run --kernel <url> --initrd <url> [--cmdline <str>] [--run-seconds <n>]
//       Build + validate + start the VM, hold it --run-seconds, then stop.
//
// Exit codes: 0 = stage succeeded, 2 = stage failed (real error on stderr).
//
// QUEUE AFFINITY (Stage 0A Queue-Affinity Repair):
//   A VZVirtualMachine is bound to an associated dispatch queue. If no queue is
//   supplied it defaults to the main queue, and EVERY property access and
//   method call (start/stop/state/...) must occur on that associated queue.
//   The original prototype created the VM implicitly on a Swift-concurrency
//   worker thread while calling start() from a different cooperative-pool
//   thread -> dispatch_assert_queue_fail -> SIGILL.
//
//   Fix (方案 A): an explicit dedicated serial DispatchQueue `vmQueue` is passed
//   to `VZVirtualMachine(configuration:queue:)`, and ALL lifecycle operations
//   (create / start / state / stop) are executed ON vmQueue. The Swift
//   concurrency surface is avoided here on purpose: the whole stage runs on a
//   global dispatch queue (never the cooperative pool and never vmQueue), and
//   only blocks on a DispatchSemaphore / DispatchGroup — so there is no
//   same-queue deadlock and no @Sendable capture of the non-Sendable VM.
//   A DispatchSpecificKey marker proves every lifecycle step actually ran on
//   vmQueue (see VM_QUEUE_POLICY self-check).

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
    fail(sub, "missing --kernel/--initrd (required for Stage 0A x86_64 Linux boot)")
}

let cmdline = arg("--cmdline", from: args)
    ?? "console=hvc0 init=/bin/sh"
let runSeconds = Int(arg("--run-seconds", from: args) ?? "8") ?? 8

guard FileManager.default.fileExists(atPath: kernelURL.path) else {
    fail(sub, "kernel not found at \(kernelURL.path)")
}
guard FileManager.default.fileExists(atPath: initrdURL.path) else {
    fail(sub, "initrd not found at \(initrdURL.path)")
}

// ----- build the x86_64 Linux VM configuration -----
func buildConfig() -> VZVirtualMachineConfiguration {
    let config = VZVirtualMachineConfiguration()

    // VZLinuxBootLoader requires a VZGenericPlatformConfiguration.
    config.platform = VZGenericPlatformConfiguration()

    // x86_64 Linux boot via Virtualization.framework.
    // VZLinuxBootLoader(kernelURL:) + .commandLine / .initrdURL properties.
    let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
    bootLoader.commandLine = cmdline
    bootLoader.initialRamdiskURL = initrdURL
    config.bootLoader = bootLoader

    // CPU: stay within VZ allowed range for this host.
    let maxCPU = VZVirtualMachineConfiguration.maximumAllowedCPUCount
    let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
    config.cpuCount = min(max(minCPU, 2), maxCPU)

    // Memory: 512 MiB is plenty for a headless init=/bin/sh boot.
    config.memorySize = 512 * 1024 * 1024

    // NETWORK: deliberately empty -> NETWORK_DEVICE_COUNT = 0 (Stage 0A requirement).
    config.networkDevices = []

    // One virtio console so the guest's console=hvc0 has a device.
    let console = VZVirtioConsoleDeviceConfiguration()
    let consolePort = VZVirtioConsolePortConfiguration()
    consolePort.isConsole = true
    console.ports[0] = consolePort
    config.consoleDevices = [console]

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
    emit([
        "stage": "validate",
        "ok": configValid,
        "isSupported": isSupported,
        "cpuArch": "x86_64",
        "cpuCount": config.cpuCount,
        "memoryBytes": config.memorySize,
        "networkDeviceCount": config.networkDevices.count,
        "kernelPresent": true,
        "initrdPresent": true,
        "error": validateError as Any
    ])
    exit(configValid ? 0 : 2)
}

// ======================================================================
else if sub == "run" {
    // --- Queue-affinity plumbing (Stage 0A Queue-Affinity Repair) ---
    // Dedicated serial queue bound to the VM, plus a marker key used to PROVE
    // every lifecycle op actually executes on this exact queue.
    let vmQueueKey = DispatchSpecificKey<String>()
    let vmQueueLabel = "com.localmcpdevrunner.stage0a.vz"
    let vmQueue = DispatchQueue(label: vmQueueLabel, qos: .userInitiated)
    vmQueue.setSpecific(key: vmQueueKey, value: vmQueueLabel)

    // Lifecycle outcomes.
    var vmStart = false
    var vmRunning = false
    var vmStop = false
    var vmFinalState = "unknown"
    var startErrorStr = ""
    var coldStartMs = -1

    // Queue-affinity self-check evidence.
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

        // 1) CREATE on vmQueue (proves create affinity).
        var vm: VZVirtualMachine!
        vmQueue.sync {
            vmCreateQueue = (DispatchQueue.getSpecific(key: vmQueueKey) != nil) ? vmQueueLabel : "OTHER"
            vm = VZVirtualMachine(configuration: config, queue: vmQueue)
        }

        let startT = Date()

        // 2) START on vmQueue (proves start affinity).
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

        // 3) poll RUNNING on vmQueue.
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

            // 4) hold the VM for --run-seconds.
            Thread.sleep(forTimeInterval: Double(runSeconds))

            // 5) STOP on vmQueue (proves stop affinity).
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

        // Queue-affinity self-check: all three lifecycle steps must land on the
        // SAME associated queue (vmQueueLabel). Derived from the
        // DispatchSpecificKey marker captured inside each op's closure — not
        // from any assumption about which thread Swift concurrency runs on.
        let policy: String
        if vmCreateQueue == vmQueueLabel && vmStartQueue == vmQueueLabel && vmStopQueue == vmQueueLabel {
            policy = "PASS"
        } else if vmCreateQueue == vmQueueLabel {
            policy = "PARTIAL_CREATE_ONLY"
        } else {
            policy = "FAIL"
        }

        emit([
            "stage": "run",
            "ok": vmStart && vmRunning && vmStop,
            "isSupported": isSupported,
            "cpuArch": "x86_64",
            "networkDeviceCount": config.networkDevices.count,
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

    // The whole stage runs on a GLOBAL dispatch queue (never the cooperative
    // pool and never vmQueue). The main thread only blocks on the semaphore,
    // and the stage only blocks on vmQueue (a different thread) — so there is
    // no same-queue deadlock.
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        runStage()
        sem.signal()
    }
    sem.wait()
    // runStage calls exit() internally; this is a fallback.
    exit(0)
}

// ======================================================================
else {
    fail(sub, "unknown subcommand '\(sub)'; use 'validate' or 'run'")
}
