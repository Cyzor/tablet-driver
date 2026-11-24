import Foundation
@main enum T {
  static func main() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dp-\(UUID())")
    try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let summary = tmp.appendingPathComponent("mocktab-info-0x520D-x.json")
    try! #"{"hello":"world"}"#.write(to: summary, atomically: true, encoding: .utf8)
    let log = tmp.appendingPathComponent("mocktab-raw-x.txt")
    try! "line one\nline two\n".write(to: log, atomically: true, encoding: .utf8)


    // With a raw log
    let zip = DiagnosticPackage.build(summaryURL: summary, rawLogURL: log, productID: "0x520D")
    expect(zip != nil, "archive is produced")
    guard let zip else { finish() }
    expect(zip.lastPathComponent.hasPrefix("mocktab-diagnostics-0x520D-"), "archive name")
    expect(zip.pathExtension == "zip", "archive extension")
    expect(FileManager.default.fileExists(atPath: zip.path), "archive exists on disk")

    // Unzip and verify contents round-trip
    let out = tmp.appendingPathComponent("out")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-x", "-k", zip.path, out.path]
    try! p.run(); p.waitUntilExit()
    expect(p.terminationStatus == 0, "archive unzips")
    let stem = zip.deletingPathExtension().lastPathComponent
    let root = out.appendingPathComponent(stem)
    expect(FileManager.default.fileExists(atPath: root.path), "expands to one named folder")
    let got = (try? String(contentsOf: root.appendingPathComponent("full-log.txt"), encoding: .utf8))
    expect(got == "line one\nline two\n", "raw log survives byte-for-byte")
    let sum = (try? String(contentsOf: root.appendingPathComponent("summary.json"), encoding: .utf8))
    expect(sum == #"{"hello":"world"}"#, "summary survives")
    // No AppleDouble sidecars. `--sequesterRsrc` produced a `__MACOSX/._*`
    // entry per file on a real archive, doubling its apparent contents.
    let all = FileManager.default.enumerator(atPath: out.path)?
        .compactMap { $0 as? String } ?? []
    expect(!all.contains { $0.hasPrefix("__MACOSX") }, "archive has no __MACOSX directory")
    expect(!all.contains { ($0 as NSString).lastPathComponent.hasPrefix("._") },
          "archive has no AppleDouble sidecars")
    let entries = Set(
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    expect(entries == ["summary.json", "full-log.txt", "README.txt"],
          "archive holds exactly the three expected files")

    let readme = (try? String(contentsOf: root.appendingPathComponent("README.txt"), encoding: .utf8)) ?? ""
    expect(readme.contains("No keystrokes"), "README states the privacy claim")
    expect(readme.contains("full-log.txt"), "README lists the log when present")
    expect(readme.hasPrefix("MockTab diagnostics"), "README opens with what this is")
    expect(readme.contains("MockTab MockTap Metrics"), "README carries the signature")
    // Signature and date sign off together, after the body.
    let signed = DiagnosticPackage.readme(
        hasRawLog: true, date: Date(timeIntervalSince1970: 1_790_000_000))
    let tail = signed.split(separator: "\n", omittingEmptySubsequences: true).suffix(2)
    expect(tail.first == "MockTab MockTap Metrics", "signature is second-to-last")
    expect(tail.last?.count == 10 && tail.last?.filter { $0 == "-" }.count == 2,
          "date signs off in yyyy-MM-dd")

    // Without a raw log
    let zip2 = DiagnosticPackage.build(summaryURL: summary, rawLogURL: nil, productID: "0x00F4")
    expect(zip2 != nil, "archive without a raw log")
    expect(!DiagnosticPackage.readme(hasRawLog: false).contains("full-log.txt"),
          "README omits the log when absent")

    // With recent activity
    let zip3 = DiagnosticPackage.build(
        summaryURL: summary, rawLogURL: nil, recentText: "recent lines\n", productID: "0x0375")
    expect(zip3 != nil, "archive with recent activity")
    if let zip3 {
        let out3 = tmp.appendingPathComponent("out3")
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        q.arguments = ["-x", "-k", zip3.path, out3.path]
        try! q.run(); q.waitUntilExit()
        let root3 = out3.appendingPathComponent(zip3.deletingPathExtension().lastPathComponent)
        let recent = try? String(contentsOf: root3.appendingPathComponent("recent.txt"), encoding: .utf8)
        expect(recent == "recent lines\n", "recent activity survives")
    }
    expect(DiagnosticPackage.readme(hasRawLog: false, hasRecent: true).contains("recent.txt"),
          "README lists recent activity when present")
    expect(!DiagnosticPackage.readme(hasRawLog: false).contains("recent.txt"),
          "README omits recent activity when absent")

    // Missing raw log file must not abort the package
    let ghost = tmp.appendingPathComponent("nope.txt")
    expect(DiagnosticPackage.build(summaryURL: summary, rawLogURL: ghost, productID: "0x1") != nil,
          "a missing raw log still produces an archive")

    // The round-trip checks above cannot catch a missing `--noextattr`: the
    // staged copies are stripped first, so in-process there is never an
    // attribute left for ditto to serialize. The signed app hits the case the
    // harness cannot — a real submission arrived with a `._` sidecar per file,
    // each holding only `com.apple.provenance`. Assert the flag itself, since
    // behavior here would pass either way.
    let sourcePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
    if let source = try? String(contentsOfFile: sourcePath, encoding: .utf8) {
        expect(source.contains("\"--noextattr\""), "ditto is told not to serialize xattrs")
        expect(source.contains("\"--norsrc\""), "ditto is told not to serialize resource forks")
        expect(!source.contains("\"--sequesterRsrc\""), "ditto does not sequester resource forks")
    } else {
        expect(false, "source file readable for the flag checks")
    }

    finish()
  }
}
