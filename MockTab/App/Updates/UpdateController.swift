// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine

/// Update state for the Info pane's MockTab row.
///
/// MockTab itself never opens a connection: every network step runs in the
/// bundled `MockTabUpdater` helper, which exits when its step ends or when
/// MockTab quits. Nothing here opens a window, posts a notification, or takes
/// focus; a result only changes the row.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    struct Offer: Equatable {
        /// "0.6.2", or "0.6.1 snapshot, Nov 11".
        let display: String
        let notes: [String]
        let url: String
        let sha256: String?
        /// False when the feed needs a newer helper than this build carries.
        var installable = true
        /// A test build, reached only by an Option check from a release.
        var isSnapshot = false
    }

    enum Phase: Equatable {
        case idle
        case checking
        /// `snapshotAvailable`: a test build newer than this release exists.
        case upToDate(snapshotAvailable: Bool)
        case available(Offer)
        case downloading(Offer, percent: Int)
        case verifying(Offer)
        /// Staged and verified; the swap happens at quit.
        case ready(Offer)
        case unreachable
        /// The check worked but the download didn't; `host` is where it
        /// was to come from.
        case downloadFailed(Offer, host: String, relaunch: Bool)
        /// The feed answered with something MockTab can't read.
        case unreadable
        case rejected(Offer)
        /// The installer couldn't start; MockTab kept running as it was.
        case installFailed(Offer)
        /// A newer MockTab exists, but not for this Mac's macOS.
        case needsSystem(display: String, minimum: String)
        case updated(display: String, notes: [String])
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?

    @Published var checksAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: Self.autoKey)
            scheduleAutomaticChecks()
        }
    }

    // Hidden keys for simulating a cycle; tools/updater/make-feed.sh sets them.
    // UpdateFeedOverride: file:// or http://127.0.0.1 feed only.
    // UpdateSimulateRunningVersion: e.g. "0.6.0".
    private static let autoKey = "checkForUpdatesAutomatically"
    private static let feedOverrideKey = "UpdateFeedOverride"
    private static let simulateKey = "UpdateSimulateRunningVersion"
    /// Written before an install; read once at the next launch.
    private static let pendingKey = "_updateInstallPending"
    /// The app's language with the system's region, so dates match the
    /// surrounding text.
    static var textLocale: Locale {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: Locale.current.region.map { "\(language)_\($0.identifier)" } ?? language)
    }

    private static let lastCheckedKey = "updateLastChecked"
    /// Written by the helper when its last-moment recheck refuses an update.
    private static let installFailedKey = "_updateInstallFailed"
    private static let feed = "https://mocktab.org/latest.json"

    private var helper: Process?
    private var installOnQuit = false
    private var timer: Timer?

    private init() {
        checksAutomatically = UserDefaults.standard.bool(forKey: Self.autoKey)
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date
    }

    // MARK: - Identity

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MockTabUpdater")
    }

    var hasHelper: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }

    /// The label the helper compares against; the simulation key wins.
    /// Simulation keys count only in snapshot and development builds.
    private func simulationValue(_ key: String) -> String? {
        Bundle.main.isReleaseBuild ? nil : UserDefaults.standard.string(forKey: key)
    }

    private var runningLabel: String {
        simulationValue(Self.simulateKey) ?? Bundle.main.versionLabel
    }

    var runningDisplay: String {
        simulationValue(Self.simulateKey)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
    }

    private var feedURL: String {
        guard let override = simulationValue(Self.feedOverrideKey),
              let url = URL(string: override),
              url.isFileURL || (url.scheme == "http" && url.host == "127.0.0.1")
        else { return Self.feed }
        return override
    }

    private var feedIsLocal: Bool { feedURL != Self.feed }

    /// Replacing the app needs a writable bundle outside App Translocation.
    var canInstallInPlace: Bool {
        let path = Bundle.main.bundlePath
        let parent = (path as NSString).deletingLastPathComponent
        return !path.contains("/AppTranslocation/")
            && FileManager.default.isWritableFile(atPath: parent)
            && FileManager.default.isWritableFile(atPath: path)
    }

    /// On the app's own volume, since the swap can't cross volumes. The
    /// path is kept so the next launch can remove what an interrupted
    /// install left behind.
    private var stagingDirectory: URL?
    private static let stagingKey = "_updateStaging"

    private func makeStagingDirectory() -> URL? {
        let dir = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: URL(fileURLWithPath: Bundle.main.bundlePath), create: true)
        if let dir { UserDefaults.standard.set(dir.path, forKey: Self.stagingKey) }
        return dir
    }

    /// Only ever a system temporary folder, whatever the setting says.
    private func removeLeftoverStaging() {
        if let path = UserDefaults.standard.string(forKey: Self.stagingKey),
           path.contains("/TemporaryItems/") {
            try? FileManager.default.removeItem(atPath: path)
        }
        UserDefaults.standard.removeObject(forKey: Self.stagingKey)
    }

    // MARK: - Launch

    func start() {
        // An install cut short (logout, crash) can leave a copy of the app.
        removeLeftoverStaging()
        let failure = UserDefaults.standard.string(forKey: Self.installFailedKey)
        UserDefaults.standard.removeObject(forKey: Self.installFailedKey)
        if let pending = UserDefaults.standard.dictionary(forKey: Self.pendingKey) {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            let display = pending["display"] as? String ?? runningDisplay
            if pending["from"] as? String != Bundle.main.versionLabel {
                phase = .updated(display: display, notes: pending["notes"] as? [String] ?? [])
            } else if let failure {
                // The helper records the kind: only a failed check is a rejection.
                let offer = Offer(display: display, notes: [], url: pending["url"] as? String ?? "", sha256: nil)
                phase = failure == "rejected" ? .rejected(offer) : .installFailed(offer)
            }
        }
        scheduleAutomaticChecks()
    }

    /// Once a week, counted from the last check that got an answer, manual
    /// or automatic. Looked at after launch (once the driver settles) and
    /// every few hours while MockTab runs; a failed check comes due again at
    /// the next look. In-app only: nothing is left behind when MockTab quits.
    private func scheduleAutomaticChecks() {
        timer?.invalidate()
        timer = nil
        guard checksAutomatically, hasHelper else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    private static let automaticInterval: TimeInterval = 7 * 24 * 60 * 60

    private func checkIfDue() {
        guard checksAutomatically else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.automaticInterval { return }
        check(manual: false)
    }

    // MARK: - Actions

    /// The menu item. Without a helper, the website does the check.
    func checkFromMenu(snapshot: Bool = false) {
        guard hasHelper else { openUpdatePage(); return }
        SettingsWindowManager.shared.show()
        SettingsWindowManager.shared.showTab(.info)
        check(manual: true, snapshot: snapshot)
    }

    /// `snapshot` is the Option check: the only way a release build is
    /// offered a snapshot. Automatic checks never ask.
    func check(manual: Bool, snapshot: Bool = false) {
        switch phase {
        case .checking, .downloading, .verifying, .ready: return
        default: break
        }
        // An automatic check never replaces what's on screen unless it finds
        // something, and never shows a failure.
        if manual { phase = .checking }
        let args = ["check", "--running", runningLabel, "--feed", feedURL] + (snapshot ? ["--snapshot"] : [])
        runHelper(args) { [weak self] line in
            guard let self else { return }
            switch line["state"] as? String {
            case "available":
                self.noteChecked()
                self.phase = .available(Self.offer(from: line))
            case "unsupported":
                self.noteChecked()
                if manual {
                    self.phase = .needsSystem(display: Self.display(from: line),
                                              minimum: line["minimumSystemVersion"] as? String ?? "")
                }
            case "upToDate":
                self.noteChecked()
                if manual { self.phase = .upToDate(snapshotAvailable: line["snapshot"] != nil) }
            case "failed":
                if manual { self.phase = line["kind"] as? String == "feed" ? .unreadable : .unreachable }
            default: break
            }
        }
    }

    func skip() {
        phase = .idle
    }

    private func noteChecked() {
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)
    }

    func install(relaunch: Bool) {
        guard case .available(let offer) = phase else { return }
        guard canInstallInPlace, let staging = makeStagingDirectory() else { openDownload(offer); return }
        stagingDirectory = staging
        phase = .downloading(offer, percent: 0)
        var args = ["stage", "--running", runningLabel, "--url", offer.url, "--dest", staging.path]
        if let sha = offer.sha256 { args += ["--sha256", sha] }
        if feedIsLocal { args.append("--local-ok") }
        runHelper(args) { [weak self] line in
            guard let self else { return }
            switch line["state"] as? String {
            case "progress":
                self.phase = .downloading(offer, percent: line["percent"] as? Int ?? 0)
            case "verifying":
                self.phase = .verifying(offer)
            case "staged":
                self.installOnQuit = true
                self.phase = .ready(offer)
                // Never under a capture; it waits for Relaunch Now instead.
                if relaunch { self.relaunchNow() }
            case "failed":
                // Not "couldn't reach mocktab.org": the feed answered, and
                // the download comes from somewhere else.
                switch line["kind"] as? String {
                case "network": self.phase = .downloadFailed(offer, host: URL(string: offer.url)?.host ?? "", relaunch: relaunch)
                case "rejected", "feed": self.phase = .rejected(offer)
                default: self.phase = .installFailed(offer)
                }
            default: break
            }
        }
    }

    func retryDownload() {
        guard case .downloadFailed(let offer, _, let relaunch) = phase else { return }
        phase = .available(offer)
        install(relaunch: relaunch)
    }

    func cancel() {
        helper?.terminate()
        helper = nil
        if case .downloading(let offer, _) = phase { phase = .available(offer) }
    }

    func relaunchNow() {
        guard installOnQuit, !CaptureActivity.shared.isActive else { return }
        // Quitting without a running helper would leave the tablet dead.
        guard launchInstaller(relaunch: true) else {
            if case .ready(let offer) = phase { phase = .installFailed(offer) }
            return
        }
        NSApp.terminate(nil)
    }

    /// From applicationWillTerminate.
    func installIfStaged() {
        guard installOnQuit else { return }
        launchInstaller(relaunch: false)
    }

    func openUpdatePage() {
        var components = URLComponents(string: "https://mocktab.org/update.html")!
        components.fragment = Bundle.main.versionLabel
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    func openDownload(_ offer: Offer) {
        // Never a local simulation path: the browser takes the project's page.
        if feedIsLocal || offer.url.isEmpty { openUpdatePage() } else if let url = URL(string: offer.url) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Helper

    @discardableResult
    private func launchInstaller(relaunch: Bool) -> Bool {
        guard case .ready(let offer) = phase, let stagingDirectory else { return false }
        installOnQuit = false
        UserDefaults.standard.set(
            ["from": Bundle.main.versionLabel, "display": offer.display, "notes": offer.notes, "url": offer.url],
            forKey: Self.pendingKey)
        let p = Process()
        p.executableURL = helperURL
        p.arguments = ["install", "--pid", String(ProcessInfo.processInfo.processIdentifier),
                       "--running", runningLabel,
                       "--staged", stagingDirectory.appendingPathComponent("MockTab.app").path,
                       "--target", Bundle.main.bundlePath,
                       "--log", NSHomeDirectory() + "/Library/Logs/MockTabUpdater.log"]
            + (relaunch ? ["--relaunch"] : [])
        // Detached from our pipes: it must outlive this process.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            return true
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            installOnQuit = true
            return false
        }
    }

    private func runHelper(_ args: [String], onLine: @escaping @MainActor ([String: Any]) -> Void) {
        let p = Process()
        p.executableURL = helperURL
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                // Queued after the last line; a result that lands later still wins.
                Task { @MainActor in self?.helperEnded() }
                return
            }
            for lineData in buffer.lines(appending: chunk) {
                guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                nonisolated(unsafe) let line = object
                Task { @MainActor in onLine(line) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                if self.helper === proc { self.helper = nil }
            }
        }
        do {
            try p.run()
            helper = p
        } catch {
            helperEnded()
        }
    }

    /// The helper stopped, or never started, without a result line.
    /// Cancel moves the phase first, so it lands in neither case.
    private func helperEnded() {
        switch phase {
        case .checking: phase = .unreachable
        case .downloading(let offer, _), .verifying(let offer): phase = .installFailed(offer)
        default: break
        }
    }

    private static func display(from line: [String: Any]) -> String {
        let version = line["version"] as? String ?? "?"
        guard line["channel"] as? String == "snapshot", let date = (line["date"] as? String).flatMap(parseFeedDate)
        else { return version }
        return String(localized: "\(version) pre-release, \(date.formatted(.dateTime.month(.abbreviated).day().locale(Self.textLocale)))",
                      comment: "Update offer for a pre-release build: version and build date, e.g. '0.6.1 pre-release, Nov 11'")
    }

    private static func offer(from line: [String: Any]) -> Offer {
        Offer(display: display(from: line), notes: line["notes"] as? [String] ?? [],
              url: line["url"] as? String ?? "", sha256: line["sha256"] as? String,
              installable: line["installable"] as? Bool ?? true,
              isSnapshot: line["channel"] as? String == "snapshot")
    }

    private static func parseFeedDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mmX"
        return f.date(from: s)
    }
}

/// Splits the helper's output into lines. Only the pipe's handler thread
/// touches it.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    func lines(appending chunk: Data) -> [Data] {
        data.append(chunk)
        var out: [Data] = []
        while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            out.append(Data(data[data.startIndex..<newline]))
            data.removeSubrange(data.startIndex...newline)
        }
        return out
    }
}
