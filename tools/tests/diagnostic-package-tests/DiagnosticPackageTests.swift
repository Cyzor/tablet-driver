import Foundation
@main enum T {
  static func main() {
    var fails = 0, checks = 0
    func check(_ c: Bool, _ l: String) {
        checks += 1
        if !c { fails += 1; FileHandle.standardError.write(Data("FAIL: \(l)\n".utf8)) }
    }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dp-\(UUID())")
    try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let summary = tmp.appendingPathComponent("mocktab-info-0x520D-x.json")
    try! #"{"hello":"world"}"#.write(to: summary, atomically: true, encoding: .utf8)
    let log = tmp.appendingPathComponent("mocktab-raw-x.txt")
    try! "line one\nline two\n".write(to: log, atomically: true, encoding: .utf8)


    // With a raw log
    let zip = DiagnosticPackage.build(summaryURL: summary, rawLogURL: log, productID: "0x520D")
    check(zip != nil, "archive is produced")
    guard let zip else { print("\(fails) of \(checks) checks failed"); exit(1) }
    check(zip.lastPathComponent.hasPrefix("mocktab-diagnostics-0x520D-"), "archive name")
    check(zip.pathExtension == "zip", "archive extension")
    check(FileManager.default.fileExists(atPath: zip.path), "archive exists on disk")

    // Unzip and verify contents round-trip
    let out = tmp.appendingPathComponent("out")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-x", "-k", zip.path, out.path]
    try! p.run(); p.waitUntilExit()
    check(p.terminationStatus == 0, "archive unzips")
    let stem = zip.deletingPathExtension().lastPathComponent
    let root = out.appendingPathComponent(stem)
    check(FileManager.default.fileExists(atPath: root.path), "expands to one named folder")
    let got = (try? String(contentsOf: root.appendingPathComponent("full-log.txt"), encoding: .utf8))
    check(got == "line one\nline two\n", "raw log survives byte-for-byte")
    let sum = (try? String(contentsOf: root.appendingPathComponent("summary.json"), encoding: .utf8))
    check(sum == #"{"hello":"world"}"#, "summary survives")
    // No AppleDouble sidecars. `--sequesterRsrc` produced a `__MACOSX/._*`
    // entry per file on a real archive, doubling its apparent contents.
    let all = FileManager.default.enumerator(atPath: out.path)?
        .compactMap { $0 as? String } ?? []
    check(!all.contains { $0.hasPrefix("__MACOSX") }, "archive has no __MACOSX directory")
    check(!all.contains { ($0 as NSString).lastPathComponent.hasPrefix("._") },
          "archive has no AppleDouble sidecars")
    let entries = Set(
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    check(entries == ["summary.json", "full-log.txt", "README.txt"],
          "archive holds exactly the three expected files")

    let readme = (try? String(contentsOf: root.appendingPathComponent("README.txt"), encoding: .utf8)) ?? ""
    check(readme.contains("No keystrokes"), "README states the privacy claim")
    check(readme.contains("full-log.txt"), "README lists the log when present")
    check(readme.hasPrefix("MockTab diagnostics"), "README opens with what this is")
    check(readme.contains("MockTab MockTap Metrics"), "README carries the signature")
    // Signature and date sign off together, after the body.
    let signed = DiagnosticPackage.readme(
        hasRawLog: true, date: Date(timeIntervalSince1970: 1_790_000_000))
    let tail = signed.split(separator: "\n", omittingEmptySubsequences: true).suffix(2)
    check(tail.first == "MockTab MockTap Metrics", "signature is second-to-last")
    check(tail.last?.count == 10 && tail.last?.filter { $0 == "-" }.count == 2,
          "date signs off in yyyy-MM-dd")

    // Without a raw log
    let zip2 = DiagnosticPackage.build(summaryURL: summary, rawLogURL: nil, productID: "0x00F4")
    check(zip2 != nil, "archive without a raw log")
    check(!DiagnosticPackage.readme(hasRawLog: false).contains("full-log.txt"),
          "README omits the log when absent")

    // Missing raw log file must not abort the package
    let ghost = tmp.appendingPathComponent("nope.txt")
    check(DiagnosticPackage.build(summaryURL: summary, rawLogURL: ghost, productID: "0x1") != nil,
          "a missing raw log still produces an archive")

    // The round-trip checks above cannot catch a missing `--noextattr`: the
    // staged copies are stripped first, so in-process there is never an
    // attribute left for ditto to serialize. The signed app hits the case the
    // harness cannot — a real submission arrived with a `._` sidecar per file,
    // each holding only `com.apple.provenance`. Assert the flag itself, since
    // behavior here would pass either way.
    let sourcePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
    if let source = try? String(contentsOfFile: sourcePath, encoding: .utf8) {
        check(source.contains("\"--noextattr\""), "ditto is told not to serialize xattrs")
        check(source.contains("\"--norsrc\""), "ditto is told not to serialize resource forks")
        check(!source.contains("\"--sequesterRsrc\""), "ditto does not sequester resource forks")
    } else {
        check(false, "source file readable for the flag checks")
    }

    if fails == 0 { print("ok — \(checks) checks passed"); exit(0) }
    FileHandle.standardError.write(Data("\(fails) of \(checks) checks failed\n".utf8)); exit(1)
  }
}
