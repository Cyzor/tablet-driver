// gpu_stress_probe.swift — saturate the GPU on demand, standing in for the
// local-LLM inference load that triggers WindowServer/CGEventPost starvation
// (see project_gpu_starvation_cursor_lag in memory). Activity Monitor shows
// ~0% CPU under the real trigger, so this deliberately does no CPU work of
// its own — it just keeps a compute queue continuously full.
//
// Usage:
//   swiftc -O -o gpu_stress_probe gpu_stress_probe.swift -framework Metal
//   ./gpu_stress_probe [seconds]      # default 30
//
// Start it, then scrub the pen over the Dock (or wherever) while it runs.
// Ctrl-C stops it early.

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

// A deliberately heavy, dependent (non-optimizable-away) loop per thread so
// the compiler can't collapse it and the GPU stays busy rather than
// memory-bound-idle.
let kernelSource = """
#include <metal_stdlib>
using namespace metal;

kernel void burn(device float *out [[buffer(0)]],
                  uint id [[thread_position_in_grid]]) {
    float x = float(id) * 1.0000001f;
    for (int i = 0; i < 20000; i++) {
        x = fma(x, 1.0000001f, 0.0000001f);
        x = sqrt(x * x + 1.0f);
    }
    out[id] = x;
}
"""

let library: MTLLibrary
do {
    library = try device.makeLibrary(source: kernelSource, options: nil)
} catch {
    fputs("Shader compile failed: \(error)\n", stderr)
    exit(1)
}

guard let function = library.makeFunction(name: "burn") else {
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

let threadCount = 1 << 20  // 1M threads per dispatch, keeps the queue deep
guard let outBuffer = device.makeBuffer(
    length: threadCount * MemoryLayout<Float>.size, options: .storageModePrivate)
else {
    fputs("Could not allocate output buffer.\n", stderr)
    exit(1)
}

let seconds: Double = {
    if CommandLine.arguments.count > 1, let s = Double(CommandLine.arguments[1]) {
        return s
    }
    return 30.0
}()

print("Saturating GPU (\(device.name)) for \(Int(seconds))s — Ctrl-C to stop early.")
print("Scrub the pen over the Dock now.")

var stop = false
signal(SIGINT) { _ in stop = true }

let deadline = Date().addingTimeInterval(seconds)
var dispatches = 0

while !stop && Date() < deadline {
    guard let cmdBuffer = queue.makeCommandBuffer(),
          let encoder = cmdBuffer.makeComputeCommandEncoder()
    else { break }

    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(outBuffer, offset: 0, index: 0)

    let threadsPerGroup = MTLSize(
        width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)
    let groups = MTLSize(
        width: (threadCount + threadsPerGroup.width - 1) / threadsPerGroup.width,
        height: 1, depth: 1)
    encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    encoder.endEncoding()

    // Keep two in flight rather than waiting on every commit, so the queue
    // never drains empty between dispatches.
    cmdBuffer.commit()
    dispatches += 1

    if dispatches % 8 == 0 {
        cmdBuffer.waitUntilCompleted()  // backpressure so we don't queue unboundedly
    }
}

print("Done. \(dispatches) dispatches submitted.")
