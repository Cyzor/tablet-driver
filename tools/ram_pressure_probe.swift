// ram_pressure_probe.swift — hold a large resident memory footprint and keep
// it "hot" (touched, uncompressible, unswappable-in-practice), standing in
// for a local LLM's multi-GB resident weight set.
//
// Both `gpu_stress_probe` (full compute occupancy) and
// `gpu_bandwidth_stress_probe` (504 GB/s sustained streaming) produced zero
// cursor lag — ruling out raw GPU throughput as the trigger. This probe
// tests a different theory: system-wide memory *pressure* (approaching
// physical RAM capacity, forcing the compressor/swap into action) rather
// than bandwidth or compute.
//
// CAUTION: this deliberately pressures system memory and can cause
// real system-wide slowdowns/beachballing by design — that's the point,
// but save your work first. Ctrl-C exits immediately and frees everything.
//
// Usage:
//   swiftc -O -o ram_pressure_probe ram_pressure_probe.swift
//   ./ram_pressure_probe [seconds] [target-GB]
//   (defaults: 30s, target = physical RAM minus 8GB headroom)

import Foundation
#if canImport(Darwin)
import Darwin
#endif

func physicalMemoryBytes() -> UInt64 {
    var size: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &size, &len, nil, 0)
    return size
}

let args = CommandLine.arguments
let seconds: Double = args.count > 1 ? (Double(args[1]) ?? 30.0) : 30.0

let physBytes = physicalMemoryBytes()
let physGB = Double(physBytes) / 1e9
let headroomGB = 8.0
let defaultTargetGB = max(4.0, physGB - headroomGB)
let targetGB: Double = args.count > 2 ? (Double(args[2]) ?? defaultTargetGB) : defaultTargetGB

let pageSize = 4096
let targetBytes = Int(targetGB * 1e9)
let pageCount = targetBytes / pageSize

print("Physical RAM: \(String(format: "%.1f", physGB)) GB")
print("Allocating \(String(format: "%.1f", targetGB)) GB and keeping it resident for \(Int(seconds))s.")
print("Watch Activity Monitor's Memory Pressure graph. Ctrl-C to stop early.")
print("Scrub the pen over the Dock once pressure builds.")

guard let raw = mmap(nil, targetBytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
      raw != MAP_FAILED
else {
    fputs("mmap failed for \(targetGB) GB — try a smaller target.\n", stderr)
    exit(1)
}
let base = raw.assumingMemoryBound(to: UInt8.self)

var stop = false
signal(SIGINT) { _ in stop = true }

// First pass: touch every page once so it's actually committed (mmap alone
// is lazy) — this is where you'll see initial pressure ramp.
print("Committing pages...")
for i in 0..<pageCount {
    base[i * pageSize] = UInt8(i & 0xff)
    if stop { break }
}
print("Committed. Holding and re-touching to defeat compression...")

let deadline = Date().addingTimeInterval(seconds)
var passes = 0
while !stop && Date() < deadline {
    // Re-touch every page each pass — write a changing value so the
    // compressor can't just dedupe/compress a static pattern away.
    let marker = UInt8(truncatingIfNeeded: passes)
    for i in stride(from: 0, to: pageCount, by: 1) {
        base[i * pageSize] = marker
    }
    passes += 1
}

munmap(raw, targetBytes)
print("Done. \(passes) full re-touch passes completed.")
