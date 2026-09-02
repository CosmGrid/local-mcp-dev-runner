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
    config.consoleDevices = [console]

    return config
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
    // The run stage needs async VM start/stop (Virtualization.framework on
    // macOS 15 exposes VZVirtualMachine.start()/stop() as async).
    func runStage() async {
        let isSupported = VZVirtualMachine.isSupported
        if !isSupported {
            fail("run", "VZVirtualMachine.isSupported == false on this host")
        }

        let config = buildConfig()
        do { try config.validate() } catch {
            fail("run", "config.validate failed: \(error)")
        }

        let vm: VZVirtualMachine
        // VZVirtualMachine(configuration:) is non-throwing in this SDK.
        vm = VZVirtualMachine(configuration: config)

        let startT = Date()
        var vmStart = false
        var startError: String? = nil
        do {
            try await vm.start()
            vmStart = true
        } catch {
            startError = String(describing: error)
        }

        if !vmStart {
            fail("run", "vm.start() failed: \(startError ?? "unknown")")
        }

        // Confirm running state.
        var vmRunning = (vm.state == .running)
        if !vmRunning {
            for _ in 0..<20 {
                if vm.state == .running { vmRunning = true; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let runningT = Date()
        let coldStartMs = Int(runningT.timeIntervalSince(startT) * 1000)

        // Hold the VM for --run-seconds.
        try? await Task.sleep(nanoseconds: UInt64(runSeconds) * 1_000_000_000)

        // Stop the VM.
        var vmStop = false
        var stopError: String? = nil
        do {
            try await vm.stop()
            vmStop = true
        } catch {
            stopError = String(describing: error)
        }

        // Let the stop settle, then read final state.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let finalState = String(describing: vm.state)

        emit([
            "stage": "run",
            "ok": vmStart && vmRunning && vmStop,
            "isSupported": isSupported,
            "cpuArch": "x86_64",
            "networkDeviceCount": config.networkDevices.count,
            "vmStart": vmStart,
            "vmRunning": vmRunning,
            "vmStop": vmStop,
            "vmFinalState": finalState,
            "coldStartMs": coldStartMs,
            "error": stopError as Any
        ])
        exit((vmStart && vmRunning && vmStop) ? 0 : 2)
    }

    let sem = DispatchSemaphore(value: 0)
    Task {
        await runStage()
        sem.signal()
    }
    sem.wait()
    // runStage calls exit() internally before returning; this is a fallback.
    exit(0)
}

// ======================================================================
else {
    fail(sub, "unknown subcommand '\(sub)'; use 'validate' or 'run'")
}
