// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MockTab's bundled updater. MockTab runs it from Contents/Helpers.
//
// Every command prints one JSON object per line on stdout. The last line is
// the result; a failure is {"state":"failed","kind":…,"reason":…} with exit 1.
//
//   MockTabUpdater check   --running <label> --feed <url> [--snapshot]
//   MockTabUpdater stage   --running <label> --url <dmg> --dest <dir> [--sha256 <hex>]
//   MockTabUpdater install --pid <n> --running <label> --staged <app> --target <app> [--relaunch] [--log <file>]
//   MockTabUpdater verify  <app>
//
// Trust comes from this helper's own signature: an update must carry the same
// Team ID and the bundle ID of the app that contains the helper. Feeds and
// downloads must come from the project's GitHub releases or from
// mocktab.org/download, except that a feed read from file:// or 127.0.0.1
// (simulation) may point at local files.

import CryptoKit
import Darwin
import Foundation
import Security

/// Bumped when the helper's behavior changes in a way the feed may need to
/// know about; the feed's `minimumUpdater` refuses helpers older than this.
let updaterVersion = 1

// MARK: - Output

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

enum FailKind: String { case network, feed, rejected, io, usage }

func fail(_ kind: FailKind, _ reason: String) -> Never {
    emit(["state": "failed", "kind": kind.rawValue, "reason": reason])
    exit(1)
}

// MARK: - Arguments

let argv = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
func required(_ name: String) -> String {
    guard let value = option(name) else { fail(.usage, "missing \(name)") }
    return value
}

// MARK: - Versions (port of mocktab-web/update.html)

struct Label {
    let version: String
    let stamp: Date?   // nil for releases
}

func parseISO(_ s: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    for format in ["yyyy-MM-dd'T'HH:mmX", "yyyy-MM-dd'T'HH:mm:ssX", "yyyyMMdd'T'HHmmX"] {
        f.dateFormat = format
        if let d = f.date(from: s) { return d }
    }
    return nil
}

func parseLabel(_ label: String) -> Label? {
    let re = try! NSRegularExpression(pattern: #"^(\d+\.\d+\.\d+)(?:-snapshot-(\d{8}T\d{4}Z))?$"#)
    let ns = label as NSString
    guard let m = re.firstMatch(in: label, range: NSRange(location: 0, length: ns.length)) else { return nil }
    let version = ns.substring(with: m.range(at: 1))
    guard m.range(at: 2).location != NSNotFound else { return Label(version: version, stamp: nil) }
    return Label(version: version, stamp: parseISO(ns.substring(with: m.range(at: 2))))
}

func isVersion(_ s: String) -> Bool {
    s.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
}

func compareVersions(_ a: String, _ b: String) -> Int {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<3 where pa[i] != pb[i] { return pa[i] - pb[i] }
    return 0
}

/// Snapshots carry the last release's version, so a newer version always
/// wins, and within one version only a later snapshot stamp does.
///
/// A running release has no stamp in its label. `releaseBuilt` is that
/// release's own build stamp, which lets a later snapshot of the same version
/// count as newer.
func isNewer(_ candidate: Label, than running: Label, releaseBuilt: Date? = nil) -> Bool {
    let c = compareVersions(candidate.version, running.version)
    if c != 0 { return c > 0 }
    guard let cs = candidate.stamp, let rs = running.stamp ?? releaseBuilt else { return false }
    return cs > rs
}

// MARK: - System

/// "13.0" or "14.2.1".
func parseSystemVersion(_ s: String) -> OperatingSystemVersion? {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard (1...3).contains(parts.count), !parts.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
    let p = parts.compactMap { $0 }
    return OperatingSystemVersion(majorVersion: p[0], minorVersion: p.count > 1 ? p[1] : 0,
                                  patchVersion: p.count > 2 ? p[2] : 0)
}

/// An unreadable minimum counts as not met.
func systemMeets(_ minimum: String) -> Bool {
    parseSystemVersion(minimum).map(ProcessInfo.processInfo.isOperatingSystemAtLeast) ?? false
}

/// Why the app can't run on this Mac, or nil when it can.
func systemMismatch(app: String) -> String? {
    guard let bundle = Bundle(path: app),
          let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") as? [String: Any]
    else { return "the app can't be read" }
    if let minimum = info["LSMinimumSystemVersion"] as? String, !systemMeets(minimum) {
        return "it needs macOS \(minimum) or later"
    }
    #if arch(arm64)
    let native = NSBundleExecutableArchitectureARM64
    #else
    let native = NSBundleExecutableArchitectureX86_64
    #endif
    guard bundle.executableArchitectures?.contains(NSNumber(value: native)) == true else {
        return "it isn't built for this Mac's processor"
    }
    return nil
}

// MARK: - Sources

/// GitHub's releases, and the project's own site so that leaving GitHub never
/// needs a manual install.
let downloadPrefixes = ["https://github.com/Cyzor/tablet-driver/releases/download/",
                        "https://mocktab.org/download/"]

func isLocal(_ url: URL) -> Bool {
    url.isFileURL || (url.scheme == "http" && url.host == "127.0.0.1")
}

/// Checked on the standardized URL, so ".." can't climb out of the prefix.
func trusted(_ s: String, allowLocal: Bool) -> URL? {
    guard let url = URL(string: s)?.standardized else { return nil }
    if allowLocal && isLocal(url) { return url }
    return downloadPrefixes.contains(where: url.absoluteString.hasPrefix) ? url : nil
}

/// GitHub redirects a release download to its asset host, and a renamed
/// repository to its new address. The asset host's name has changed before,
/// so any host under githubusercontent.com passes; the signature and checksum
/// carry the trust.
func downloadRedirectAllowed(_ url: URL) -> Bool {
    guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
    return host == "github.com" || host.hasSuffix(".githubusercontent.com")
}

/// Follows a redirect only where `allows` says so; refusing one makes the
/// redirect response itself the result, which then fails as non-200.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    let allows: (URL) -> Bool
    init(allows: @escaping (URL) -> Bool) { self.allows = allows }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(allows) == true ? request : nil)
    }
}

func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.httpCookieStorage = nil
    config.urlCache = nil
    // Accept-Language: CFNetwork otherwise sends the user's locale.
    config.httpAdditionalHeaders = ["User-Agent": "MockTabUpdater", "Accept-Language": "*"]
    // Long enough to read and answer a firewall's first prompt.
    config.timeoutIntervalForRequest = 60
    return URLSession(configuration: config)
}

// MARK: - Parent watch

/// Exits when MockTab quits, so a check or download never outlives it.
func exitWithParent(cleanup: @escaping () -> Void = {}) {
    let parent = getppid()
    // Already orphaned: MockTab went before the watch could start.
    if parent == 1 { cleanup(); exit(2) }
    Thread.detachNewThread {
        let kq = kqueue()
        var change = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: NOTE_EXIT, data: 0, udata: nil)
        var event = kevent()
        if kevent(kq, &change, 1, nil, 0, nil) == 0 { _ = kevent(kq, nil, 0, &event, 1, nil) }
        cleanup()
        exit(2)
    }
}

// MARK: - Check

func check() {
    exitWithParent()
    guard let running = parseLabel(required("--running")) else { fail(.usage, "unparseable --running") }
    guard let feed = URL(string: required("--feed")) else { fail(.usage, "bad --feed") }
    let local = isLocal(feed)
    guard local || feed.absoluteString == "https://mocktab.org/latest.json" else { fail(.usage, "feed not allowed") }

    let data: Data
    if feed.isFileURL {
        guard let d = try? Data(contentsOf: feed) else { fail(.network, "feed unavailable") }
        data = d
    } else {
        var result: Result<Data, Error>?
        let done = DispatchSemaphore(value: 0)
        // The feed never redirects.
        URLSession(configuration: session().configuration, delegate: RedirectGuard(allows: { _ in false }), delegateQueue: nil)
            .dataTask(with: feed) { data, response, error in
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(NSError(domain: "HTTP", code: http.statusCode))
            } else { result = .success(data ?? Data()) }
            done.signal()
        }.resume()
        done.wait()
        switch result! {
        case .failure(let e): fail(.network, e.localizedDescription)
        case .success(let d): data = d
        }
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rel = json["release"] as? [String: Any], let snap = json["snapshot"] as? [String: Any],
          let relVersion = rel["version"] as? String,
          let relDate = (rel["date"] as? String).flatMap(parseISO), let relURL = rel["url"] as? String,
          let snapDateS = snap["date"] as? String, let snapDate = parseISO(snapDateS),
          let snapURL = snap["url"] as? String
    else { fail(.feed, "feed malformed") }
    // compareVersions reads three parts.
    guard isVersion(relVersion) else { fail(.feed, "feed malformed") }
    guard trusted(relURL, allowLocal: local) != nil, trusted(snapURL, allowLocal: local) != nil
    else { fail(.feed, "feed points outside the project's releases") }

    // Schema 1 and later publish a checksum for every download. A higher
    // schema only adds requirements, so it reads like the newest one known.
    let schema = json["schema"] as? Int ?? 0
    if schema >= 1, rel["sha256"] as? String == nil || snap["sha256"] as? String == nil {
        fail(.feed, "feed lacks a checksum")
    }

    let relAhead = compareVersions(relVersion, running.version) > 0
        && (running.stamp.map { relDate >= $0 } ?? true)
    // A release build sees a snapshot only when asked, and only one that's
    // ahead of the latest release.
    let wantSnapshot = argv.contains("--snapshot")
    let snapPastRelease = snapDate > relDate
    let snapAhead = running.stamp.map { snapDate > $0 }
        ?? (wantSnapshot && snapPastRelease && compareVersions(relVersion, running.version) >= 0)

    var offer: [String: Any]
    if snapAhead && (wantSnapshot ? snapPastRelease : !relAhead) {
        offer = ["channel": "snapshot", "version": relVersion, "date": snapDateS, "url": snapURL,
                 "notes": snap["notes"] ?? [], "sha256": snap["sha256"] ?? NSNull()]
        if let minimum = snap["minimumSystemVersion"] { offer["minimumSystemVersion"] = minimum }
    } else if relAhead {
        offer = ["channel": "release", "version": relVersion, "url": relURL,
                 "notes": rel["notes"] ?? [], "sha256": rel["sha256"] ?? NSNull()]
        if let minimum = rel["minimumSystemVersion"] { offer["minimumSystemVersion"] = minimum }
    } else {
        // Tells a release build that a snapshot check would find something,
        // so the app can mention it.
        let snapshotWaits = running.stamp == nil && snapPastRelease
            && compareVersions(relVersion, running.version) >= 0
        emit(snapshotWaits ? ["state": "upToDate", "snapshot": snapDateS] : ["state": "upToDate"])
        return
    }

    // Too old to install what the feed offers. A bridge is a release this
    // helper can still install, which carries a newer helper; without one,
    // report the offer for the download page only.
    offer["installable"] = true
    if (json["minimumUpdater"] as? Int ?? 0) > updaterVersion {
        if let bridge = bestBridge(json["bridges"], running: running, schema: schema, local: local) {
            offer = bridge
        } else {
            offer["installable"] = false
        }
    }

    if let minimum = offer["minimumSystemVersion"] {
        guard let minimum = minimum as? String, parseSystemVersion(minimum) != nil else { fail(.feed, "feed malformed") }
        if !systemMeets(minimum) {
            emit(["state": "unsupported", "channel": offer["channel"]!, "version": offer["version"]!,
                  "minimumSystemVersion": minimum])
            return
        }
    }
    offer["state"] = "available"
    emit(offer)
}

/// The newest bridge this helper can install on this Mac that's newer than
/// the running MockTab. Entries it can't read are skipped: their shape may
/// postdate this helper.
func bestBridge(_ value: Any?, running: Label, schema: Int, local: Bool) -> [String: Any]? {
    var best: (version: String, offer: [String: Any])?
    for entry in value as? [[String: Any]] ?? [] {
        guard let version = entry["version"] as? String,
              isVersion(version),
              let date = (entry["date"] as? String).flatMap(parseISO),
              let url = entry["url"] as? String, trusted(url, allowLocal: local) != nil,
              (entry["minimumUpdater"] as? Int ?? 0) <= updaterVersion,
              schema < 1 || entry["sha256"] is String,
              compareVersions(version, running.version) > 0, running.stamp.map({ date >= $0 }) ?? true
        else { continue }
        if let minimum = entry["minimumSystemVersion"] {
            guard let minimum = minimum as? String, systemMeets(minimum) else { continue }
        }
        if let best, compareVersions(version, best.version) <= 0 { continue }
        best = (version, ["channel": "release", "version": version, "url": url, "notes": entry["notes"] ?? [],
                          "sha256": entry["sha256"] ?? NSNull(), "installable": true, "bridge": true])
    }
    return best?.offer
}

// MARK: - Verification

func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    // A tool that can't start is an ordinary failure, not a crash.
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out, as: UTF8.self))
}

/// …/MockTab.app/Contents/Helpers/MockTabUpdater, from the kernel: argv[0]
/// is whatever the launcher chose.
func enclosingApp() -> URL? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// The enclosing MockTab's build stamp, when it's the release `running`
/// names. Read from the bundle, so an argument can't set it.
func releaseBuilt(for running: Label) -> Date? {
    guard running.stamp == nil, let app = enclosingApp()?.path,
          let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") as? [String: Any],
          info["MockTabRelease"] as? Bool == true,
          info["CFBundleShortVersionString"] as? String == running.version
    else { return nil }
    return (info["MockTabBuildStamp"] as? String).flatMap(parseISO)
}

/// This helper's Team ID and its enclosing app's bundle ID.
func ownIdentity() -> (team: String, bundleID: String) {
    var me: SecCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
          let staticMe = { var s: SecStaticCode?; SecCodeCopyStaticCode(me, [], &s); return s }(),
          SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    else { fail(.rejected, "the updater itself isn't signed") }
    guard let app = enclosingApp() else { fail(.rejected, "can't find the updater's own path") }
    guard let bundleID = Bundle(url: app)?.bundleIdentifier else { fail(.rejected, "the updater isn't inside MockTab") }
    return (team, bundleID)
}

/// Runs on this Mac; Developer ID Application leaf, same team and bundle ID,
/// notarized.
/// `anchor apple generic` already rejects ad-hoc and self-signed code.
func verify(app: String) -> String? {
    if let why = systemMismatch(app: app) { return why }
    let (team, bundleID) = ownIdentity()
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: app) as CFURL, [], &code) == errSecSuccess,
          let code else { return "not signed code" }
    let text = """
        anchor apple generic and identifier "\(bundleID)" \
        and certificate leaf[subject.OU] = "\(team)" \
        and certificate 1[field.1.2.840.113635.100.6.2.6] \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] \
        and notarized
        """
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return "bad requirement" }
    // 1 << 30: kSecCSEnforceRevocationChecks, missing from the Swift overlay.
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate | (1 << 30))
    var error: Unmanaged<CFError>?
    if SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error) != errSecSuccess {
        return "signature check failed (\(error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0))"
    }
    // `notarized` is settled from the staple, the system's ticket cache, or
    // Apple's online check. No staple test: xcrun belongs to developer tools,
    // and asks to install them on a Mac without.
    if run("/usr/sbin/spctl", ["--assess", "--type", "exec", app]).status != 0 { return "Gatekeeper rejected it" }
    return nil
}

func label(ofApp app: String) -> Label? {
    guard let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") as? [String: Any],
          let version = info["CFBundleShortVersionString"] as? String else { return nil }
    if info["MockTabRelease"] as? Bool == true { return Label(version: version, stamp: nil) }
    return Label(version: version, stamp: (info["MockTabBuildStamp"] as? String).flatMap(parseISO))
}

// MARK: - Stage

final class Downloader: NSObject, URLSessionDownloadDelegate {
    var finished: URL?
    var error: Error?
    let done = DispatchSemaphore(value: 0)
    var lastReported = -1
    let keep: URL

    init(keep: URL) { self.keep = keep }

    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Only a GitHub download redirects; one from mocktab.org never does.
        // A local (simulated) source may, so the rule can be tested.
        let origin = task.originalRequest?.url
        let mayRedirect = origin?.host == "github.com" || origin.map(isLocal) == true
        RedirectGuard(allows: { mayRedirect && downloadRedirectAllowed($0) })
            .urlSession(s, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
        if percent != lastReported { lastReported = percent; emit(["state": "progress", "percent": percent]) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            error = NSError(domain: "HTTP", code: http.statusCode)
            return
        }
        try? FileManager.default.removeItem(at: keep)
        do { try FileManager.default.moveItem(at: location, to: keep); finished = keep } catch { self.error = error }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { self.error = error }
        done.signal()
    }
}

func sha256(of url: URL) -> String {
    var hasher = SHA256()
    let h = try! FileHandle(forReadingFrom: url)
    while let chunk = try! h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Mounts read-only and hidden from Finder. `diskutil image attach` replaces
/// `hdiutil attach` (deprecated on macOS 27); older systems lack it.
func attachImage(_ dmg: URL) -> String? {
    let point = FileManager.default.temporaryDirectory.appendingPathComponent("mocktab-update-\(getpid())")
    try? FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)
    var result = run("/usr/sbin/diskutil", ["image", "attach", "--plist", "--readOnly", "--nobrowse",
                                            "--mountPoint", point.path, dmg.path])
    if result.status != 0 {
        result = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                          "-mountpoint", point.path, "-plist", dmg.path])
    }
    guard result.status == 0,
          let start = result.output.range(of: "<?xml"),
          let plist = try? PropertyListSerialization.propertyList(
              from: Data(result.output[start.lowerBound...].utf8), format: nil) as? [String: Any]
    else { return nil }
    return (plist["system-entities"] as? [[String: Any]])?.compactMap { $0["mount-point"] as? String }.first
}

func stage() {
    guard let running = parseLabel(required("--running")) else { fail(.usage, "unparseable --running") }
    let dest = URL(fileURLWithPath: required("--dest"))
    let fm = FileManager.default
    exitWithParent { try? fm.removeItem(at: dest) }
    // Local sources only when the app itself runs a local (simulated) feed.
    guard let source = trusted(required("--url"), allowLocal: argv.contains("--local-ok"))
    else { fail(.feed, "download isn't from the project's releases") }

    try? fm.removeItem(at: dest)
    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let dmg = dest.appendingPathComponent("update.dmg")

    let downloader = Downloader(keep: dmg)
    let s = URLSession(configuration: session().configuration, delegate: downloader, delegateQueue: nil)
    s.downloadTask(with: source).resume()
    downloader.done.wait()
    guard downloader.finished != nil else {
        try? fm.removeItem(at: dest)
        fail(.network, downloader.error?.localizedDescription ?? "download failed")
    }

    emit(["state": "verifying"])
    if let expected = option("--sha256"), sha256(of: dmg) != expected.lowercased() {
        try? fm.removeItem(at: dest)
        fail(.rejected, "the download doesn't match the published checksum")
    }

    guard let mount = attachImage(dmg) else { try? fm.removeItem(at: dest); fail(.rejected, "the disk image couldn't be opened") }

    let staged = dest.appendingPathComponent("MockTab.app").path
    let copy = run("/usr/bin/ditto", ["\(mount)/MockTab.app", staged])
    if run("/usr/sbin/diskutil", ["eject", mount]).status != 0 { _ = run("/usr/bin/hdiutil", ["detach", "-force", mount]) }
    try? fm.removeItem(at: dmg)
    guard copy.status == 0 else { try? fm.removeItem(at: dest); fail(.io, "copy failed") }

    guard let candidate = label(ofApp: staged), isNewer(candidate, than: running, releaseBuilt: releaseBuilt(for: running)) else {
        try? fm.removeItem(at: dest)
        fail(.rejected, "the download isn't newer than the running MockTab")
    }
    if let why = verify(app: staged) { try? fm.removeItem(at: dest); fail(.rejected, why) }
    emit(["state": "staged", "path": staged])
}

// MARK: - Install

func install() {
    guard let pid = pid_t(required("--pid")) else { fail(.usage, "bad --pid") }
    guard let running = parseLabel(required("--running")) else { fail(.usage, "unparseable --running") }
    let staged = required("--staged"), target = required("--target")
    let relaunch = argv.contains("--relaunch")
    let logHandle: FileHandle? = option("--log").flatMap { path in
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let h = FileHandle(forWritingAtPath: path)
        h?.seekToEndOfFile()
        return h
    }
    let start = Date()
    func note(_ s: String) {
        logHandle?.write(Data("\(Date()) +\(Int(Date().timeIntervalSince(start) * 1000))ms \(s)\n".utf8))
    }

    // The staged copy may have sat for hours where anything running as this
    // user can write, so check it again. Runs while MockTab quits, so
    // the check doesn't lengthen the pause in pen input.
    var rejection: String?
    let built = releaseBuilt(for: running)
    let checked = DispatchGroup()
    checked.enter()
    Thread.detachNewThread {
        if let candidate = label(ofApp: staged), isNewer(candidate, than: running, releaseBuilt: built) {
            rejection = verify(app: staged)
        } else {
            rejection = "the staged copy isn't newer than the running MockTab"
        }
        checked.leave()
    }

    note("waiting for pid \(pid)")
    let kq = kqueue()
    var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                        fflags: NOTE_EXIT, data: 0, udata: nil)
    var event = kevent()
    if kevent(kq, &change, 1, nil, 0, nil) == 0 { _ = kevent(kq, nil, 0, &event, 1, nil) }
    note("MockTab exited")
    checked.wait()
    note("recheck finished")

    /// Moves what's at the staged path to the Trash and removes the staging
    /// folder, which rmdir leaves alone unless it's empty.
    func clearStaging() {
        let url = URL(fileURLWithPath: staged)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        rmdir(url.deletingLastPathComponent().path)
    }

    /// Leaves the installed app as it was, says why for the next launch,
    /// and brings MockTab back if it was quitting only to update.
    func abandon(_ kind: FailKind, _ why: String) -> Never {
        note("not installed: \(why)")
        clearStaging()
        if let defaults = UserDefaults(suiteName: ownIdentity().bundleID) {
            defaults.set(kind.rawValue, forKey: "_updateInstallFailed")  // the reason is in the log
            defaults.synchronize()
        }
        if relaunch { _ = run("/usr/bin/open", [target]) }
        fail(kind, why)
    }

    if let rejection { abandon(.rejected, rejection) }

    // Atomic on APFS: the target is always one complete app.
    if renamex_np(staged, target, UInt32(RENAME_SWAP)) != 0 {
        abandon(.io, "swap failed: \(String(cString: strerror(errno)))")
    }
    note("swapped")
    clearStaging()
    note("previous copy moved to the Trash")
    if relaunch {
        let open = run("/usr/bin/open", [target])
        note("relaunch requested (open exit \(open.status))")
    }
    emit(["state": "installed"])
}

// MARK: - Main

switch argv.first {
case "check": check()
case "stage": stage()
case "install": install()
case "verify" where argv.count == 2:
    if let why = verify(app: argv[1]) { fail(.rejected, why) }
    emit(["state": "verified"])
default: fail(.usage, "usage: MockTabUpdater check|stage|install|verify …")
}
