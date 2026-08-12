// gpu_bandwidth_stress_probe.swift — saturate unified-memory bandwidth, not
// GPU compute occupancy, standing in for local-LLM inference load.
//
// `gpu_stress_probe.swift` fully pegged GPU compute occupancy (confirmed via
// the GPU History graph) with zero effect on cursor lag, and the fan never
// spun up — that kernel is register-resident math with almost no memory
// traffic. LLM inference streams huge weight tensors through unified memory
// every token, which is a completely different load shape: bandwidth-bound,
// not compute-bound. This probe streams large buffers (well beyond any
// cache) to test that theory directly.
//
// Usage:
//   swiftc -O -o gpu_bandwidth_stress_probe gpu_bandwidth_stress_probe.swift -framework Metal
//   ./gpu_bandwidth_stress_probe [seconds] [buffer-MB-per-stream]
//   (defaults: 30s, 512MB per buffer — several GB/s+ of traffic per pass)
//
// Start it, then scrub the pen over the Dock while it runs. Ctrl-C stops
// early.

import Metal
import Foundation

guard let device = MTLCreateSystemDefaultDevice() else {
    fputs("No Metal device available.\n", stderr)
    exit(1)
}
guard let queue = device.makeCommandQueue() else {
    fputs("Could not create command queue.\n", stderr)
    exit(1)
}

// Trivial per-element math so the bottleneck is memory traffic, not ALU
// work — read two large buffers, write one, every element touched exactly
// once per dispatch so nothing stays cache-resident across the run.
let kernelSource = """
#include <metal_stdlib>
using namespace metal;

kernel void streamCopy(device const float *a [[buffer(0)]],
                        device const float *b [[buffer(1)]],
                        device float *out [[buffer(2)]],
                        uint id [[thread_position_in_grid]]) {
    out[id] = a[id] * 1.0000001f + b[id];
}
"""

let library: MTLLibrary
do {
    library = try device.makeLibrary(source: kernelSource, options: nil)
} catch {
    fputs("Shader compile failed: \(error)\n", stderr)
    exit(1)
}

guard let function = library.makeFunction(name: "streamCopy") else {
    fputs("Could not find kernel function.\n", stderr)
    exit(1)
}

let pipeline: MTLComputePipelineState
do {
    pipeline = try device.makeComputePipelineState(function: function)
} catch {
    fputs("Pipeline creation failed: \(error)\n", stderr)
    exit(1)
}

let args = CommandLine.arguments
let seconds: Double = args.count > 1 ? (Double(args[1]) ?? 30.0) : 30.0
let bufferMB: Int = args.count > 2 ? (Int(args[2]) ?? 512) : 512

let elementCount = (bufferMB * 1024 * 1024) / MemoryLayout<Float>.size
let bufferBytes = elementCount * MemoryLayout<Float>.size

guard
    let bufA = device.makeBuffer(length: bufferBytes, options: .storageModePrivate),
    let bufB = device.makeBuffer(length: bufferBytes, options: .storageModePrivate),
    let bufOut = device.makeBuffer(length: bufferBytes, options: .storageModePrivate)
else {
    fputs("Could not allocate \(bufferMB)MB buffers.\n", stderr)
    exit(1)
}

// One pass touches A (read) + B (read) + Out (write) = 3x buffer size of
// traffic. Report that per dispatch so the printed throughput is meaningful.
let bytesPerDispatch = Double(bufferBytes) * 3.0

print("Streaming \(bufferMB)MB buffers (\(device.name)) for \(Int(seconds))s — Ctrl-C to stop early.")
print("Scrub the pen over the Dock now.")

var stop = false
signal(SIGINT) { _ in stop = true }

let deadline = Date().addingTimeInterval(seconds)
var dispatches = 0
let startTime = Date()

while !stop && Date() < deadline {
    guard let cmdBuffer = queue.makeCommandBuffer(),
          let encoder = cmdBuffer.makeComputeCommandEncoder()
    else { break }

    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(bufA, offset: 0, index: 0)
    encoder.setBuffer(bufB, offset: 0, index: 1)
    encoder.setBuffer(bufOut, offset: 0, index: 2)

    let threadsPerGroup = MTLSize(
        width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)
    let groups = MTLSize(
        width: (elementCount + threadsPerGroup.width - 1) / threadsPerGroup.width,
        height: 1, depth: 1)
    encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    encoder.endEncoding()

    cmdBuffer.commit()
    dispatches += 1

    // Wait every dispatch — we want sustained back-to-back memory traffic,
    // not a deep queue of compute-bound work piling up.
    cmdBuffer.waitUntilCompleted()
}

let elapsed = Date().timeIntervalSince(startTime)
let totalGB = (bytesPerDispatch * Double(dispatches)) / 1e9
let gbPerSec = totalGB / elapsed
print(String(format: "Done. %d dispatches, %.1f GB moved, ~%.1f GB/s average.",
             dispatches, totalGB, gbPerSec))
