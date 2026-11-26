// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import IOKit

/// How busy the Mac is, and with what, for the flight recorder. Sampled
/// only while MockTab's moves flow, so an idle Mac costs nothing.
///
/// CPU time is readable only for the user's own processes; macOS refuses it
/// for system ones such as WindowServer. GPU time is readable for every
/// process. Names follow `FlightRecorder.processName`: Apple's own, or
/// "another app". A sample takes 10–20 ms, so it runs on its own queue,
/// away from the delivery watch it reports beside.
final class StrainSampler: @unchecked Sendable {
    struct Sample {
        let ns: UInt64
        let busyTicks: UInt64
        let totalTicks: UInt64
        let gpuPercent: Int
        let gpuNs: [pid_t: UInt64]
        let cpuNs: [pid_t: UInt64]
    }

    static let periodNs: UInt64 = 2_000_000_000
    static let strainPercent = 85
    static let easedPercent = 70

    private let queue = DispatchQueue(label: "MockTab strain sampler", qos: .utility)
    // Caller's thread.
    private var lastRequestNs: UInt64 = 0
    // Queue-confined.
    private var previous: Sample?
    private var strainedSince: UInt64 = 0
    private var highRun = 0
    private var lowRun = 0
    private var names: [pid_t: String] = [:]

    /// Called often while moves flow; samples every `periodNs` and notes
    /// when strain starts or eases.
    func tick(now: UInt64) {
        guard now - lastRequestNs >= Self.periodNs else { return }
        lastRequestNs = now
        queue.async { [self] in
            let sample = take()
            defer { previous = sample }
            guard let previous else { return }
            let (cpu, gpu) = Self.load(previous, sample)
            if max(cpu, gpu) >= Self.strainPercent {
                highRun += 1
                lowRun = 0
                if strainedSince == 0, highRun >= 2 {
                    strainedSince = sample.ns
                    FlightRecorder.shared.note("Mac under strain: " + describe(previous, sample))
                }
            } else if max(cpu, gpu) < Self.easedPercent {
                lowRun += 1
                highRun = 0
                if strainedSince != 0, lowRun >= 2 {
                    let span = Double(sample.ns - strainedSince) / 1e9
                    strainedSince = 0
                    FlightRecorder.shared.note(String(format: "strain eased after %.0f s", span))
                }
            }
        }
    }

    /// Notes the load since the last sample, beside a late stretch. The
    /// window is at most `periodNs` long.
    func noteLoad() {
        queue.async { [self] in
            let sample = take()
            defer { previous = sample }
            guard let previous, sample.ns - previous.ns >= 200_000_000 else {
                FlightRecorder.shared.note("load around it: not sampled yet")
                return
            }
            FlightRecorder.shared.note("load around it: " + describe(previous, sample))
        }
    }

    // MARK: - Sampling

    private static func load(_ a: Sample, _ b: Sample) -> (cpu: Int, gpu: Int) {
        let total = b.totalTicks &- a.totalTicks
        let cpu = total > 0 ? Int((b.busyTicks &- a.busyTicks) * 100 / total) : 0
        return (cpu, b.gpuPercent)
    }

    private func name(_ pid: pid_t) -> String {
        if let known = names[pid] { return known }
        let found = FlightRecorder.processName(pid)
        names[pid] = found
        return found
    }

    private func describe(_ a: Sample, _ b: Sample) -> String {
        let (cpu, gpu) = Self.load(a, b)
        let wall = Double(b.ns - a.ns)
        func top(_ before: [pid_t: UInt64], _ after: [pid_t: UInt64]) -> String {
            let shares = after.compactMap { pid, ns -> (pid_t, Int)? in
                // A total that went down (a closed GPU client, a reused PID)
                // says nothing about this interval; skip it rather than wrap.
                let start = before[pid] ?? ns
                guard ns >= start else { return nil }
                let used = ns - start
                let percent = Int(Double(used) / wall * 100)
                return percent >= 10 ? (pid, percent) : nil
            }
            let named = shares.sorted { $0.1 > $1.1 }.prefix(3)
                .map { "\(name($0.0)) \($0.1)%" }
            return named.isEmpty ? "none over 10%" : named.joined(separator: ", ")
        }
        return "CPU \(cpu)% busy, GPU \(gpu)% busy; most GPU: \(top(a.gpuNs, b.gpuNs)); "
            + "most CPU among the user's apps: \(top(a.cpuNs, b.cpuNs))"
    }

    private func take() -> Sample {
        let (busy, total) = Self.cpuTicks()
        let (gpuPercent, gpuNs) = Self.gpu()
        let cpuNs = Self.processCPU()
        return Sample(ns: FlightRecorder.nowNs(), busyTicks: busy, totalTicks: total,
                      gpuPercent: gpuPercent, gpuNs: gpuNs, cpuNs: cpuNs)
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let t = load.cpu_ticks
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)  // user, system, nice
        return (busy, busy + UInt64(t.2))
    }

    /// Device utilization of the busiest GPU, and each process's GPU time.
    private static func gpu() -> (percent: Int, perProcess: [pid_t: UInt64]) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
            == KERN_SUCCESS else { return (0, [:]) }
        defer { IOObjectRelease(iterator) }
        var percent = 0
        var perProcess: [pid_t: UInt64] = [:]
        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            if let stats = property(accelerator, "PerformanceStatistics") as? [String: Any],
               let used = stats["Device Utilization %"] as? Int {
                percent = max(percent, used)
            }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(children) }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let pid = pid(fromCreator: creator),
                      let usage = property(client, "AppUsage") as? [[String: Any]]
                else { continue }
                let ns = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                perProcess[pid, default: 0] += ns
            }
        }
        return (percent, perProcess)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// "pid 184, WindowServer" → 184.
    private static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid "), let comma = creator.firstIndex(of: ",") else { return nil }
        return pid_t(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma])
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// CPU time of every process macOS lets this user read.
    private static func processCPU() -> [pid_t: UInt64] {
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = Int(proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size)))
        var result: [pid_t: UInt64] = [:]
        var info = rusage_info_v2()
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard ok == 0 else { continue }
            result[pid] = (info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom
        }
        return result
    }
}
