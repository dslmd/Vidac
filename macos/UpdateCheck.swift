import AppKit

/// Looks for a newer release on GitHub, at most once a day, and says so.
/// It never downloads or installs anything: the user is sent to the release
/// page. The request carries no identifying data: no version, system or user
/// information, no cookies, and a fixed generic User-Agent.
final class UpdateChecker {
    struct Release: Equatable {
        /// The tag without a leading "v", for display.
        let version: String
        let page: URL
    }
    enum Outcome {
        case available(Release)
        case upToDate
        case failed
    }

    static let endpoint = URL(string: "https://api.github.com/repos/dslmd/Vidac/releases/latest")!
    static let interval: TimeInterval = 24 * 3600
    static var runningVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    /// A newer release is known (from this launch or an earlier one).
    private(set) var available: Release?
    /// Called on the main thread when the known newer release changes. `isNew`
    /// is true the first time this version has been seen.
    var onChange: ((Release?, _ isNew: Bool) -> Void)?
    private var waiting: [(Outcome) -> Void] = []
    private var running = false
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    /// Automatic lookups are on unless this default is set to false (a setting a later stage may expose).
    var automaticChecksEnabled: Bool { (defaults.object(forKey: "AutomaticUpdateCheck") as? Bool) ?? true }

    func start() {
        guard Self.runningVersion != nil else { return }
        if let tag = defaults.string(forKey: "UpdateAvailableTag"),
            let page = defaults.string(forKey: "UpdateAvailableURL").flatMap(URL.init),
            Self.isAcceptable(page), Self.isNewer(tag, than: Self.runningVersion ?? tag)
        {
            available = Release(version: Self.display(tag), page: page)
            onChange?(available, false)
        } else {
            clearStored()
        }
        // Shortly after launch, then every few hours in case the app stays open for days.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkIfDue() {
        guard automaticChecksEnabled, !running else { return }
        let last = defaults.double(forKey: "UpdateLastCheck")
        if last > 0, Date().timeIntervalSince1970 - last < Self.interval, Date().timeIntervalSince1970 >= last { return }
        fetch { _ in }
    }
    /// Checks now, whatever the clock says, and reports the result.
    func checkNow(_ completion: @escaping (Outcome) -> Void) { fetch(completion) }

    private func fetch(_ completion: @escaping (Outcome) -> Void) {
        guard let current = Self.runningVersion else {
            completion(.failed)
            return
        }
        waiting.append(completion)
        guard !running else { return }
        running = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Vidac", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, _ in
            session.finishTasksAndInvalidate()
            var outcome = Outcome.failed
            if let http = response as? HTTPURLResponse, http.statusCode == 200, let data, data.count < 2_000_000,
                let found = Self.parse(data)
            {
                outcome =
                    Self.isNewer(found.tag, than: current)
                    ? .available(Release(version: Self.display(found.tag), page: found.page)) : .upToDate
            }
            DispatchQueue.main.async { self?.finish(outcome) }
        }.resume()
    }

    private func finish(_ outcome: Outcome) {
        running = false
        let before = available
        switch outcome {
        case .available(let release):
            defaults.set(Date().timeIntervalSince1970, forKey: "UpdateLastCheck")
            defaults.set(release.version, forKey: "UpdateAvailableTag")
            defaults.set(release.page.absoluteString, forKey: "UpdateAvailableURL")
            available = release
        case .upToDate:
            defaults.set(Date().timeIntervalSince1970, forKey: "UpdateLastCheck")
            clearStored()
            available = nil
        case .failed:
            break  // offline or rate limited: say nothing and try again later
        }
        if available != before { onChange?(available, available != nil) }
        let callbacks = waiting
        waiting = []
        for callback in callbacks { callback(outcome) }
    }
    private func clearStored() {
        defaults.removeObject(forKey: "UpdateAvailableTag")
        defaults.removeObject(forKey: "UpdateAvailableURL")
    }

    // MARK: Parsing and comparing

    /// The release page must be an https GitHub page; anything else in the reply is ignored.
    static func isAcceptable(_ url: URL) -> Bool {
        url.scheme == "https" && (url.host == "github.com" || url.host == "www.github.com")
    }
    static func parse(_ data: Data) -> (tag: String, page: URL)? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tag = object["tag_name"] as? String,
            !tag.isEmpty, let text = object["html_url"] as? String, let page = URL(string: text), isAcceptable(page)
        else { return nil }
        return (tag, page)
    }
    static func display(_ tag: String) -> String { tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag }

    /// Compares dotted version numbers ("0.10.0" is newer than "0.9.2"). A
    /// tag with a suffix such as "-beta" is older than the same number without one.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func split(_ text: String) -> (numbers: [Int], prerelease: Bool)? {
            let core = display(text.trimmingCharacters(in: .whitespaces))
            let pieces = core.split(maxSplits: 1, omittingEmptySubsequences: false) { $0 == "-" || $0 == "+" }
            guard let head = pieces.first, !head.isEmpty else { return nil }
            let numbers = head.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !numbers.contains(where: { $0 == nil }) else { return nil }
            return (numbers.compactMap { $0 }, text.contains("-") && !text.contains("+"))
        }
        guard let new = split(tag), let old = split(current) else { return false }
        for index in 0..<max(new.numbers.count, old.numbers.count) {
            let a = index < new.numbers.count ? new.numbers[index] : 0
            let b = index < old.numbers.count ? old.numbers[index] : 0
            if a != b { return a > b }
        }
        return old.prerelease && !new.prerelease
    }
}

// MARK: Menu and dialogs

extension AppDelegate {
    func updateAvailabilityChanged(_ release: UpdateChecker.Release?, isNew: Bool) {
        updateMenuItem?.isHidden = release == nil
        guard let release, isNew else { return }
        // Told once per version, even if ignored; the menu item stays.
        if UserDefaults.standard.string(forKey: "UpdateNoticeTag") != release.version {
            UserDefaults.standard.set(release.version, forKey: "UpdateNoticeTag")
            player?.showUpdateNotice(release)
        }
    }

    @objc func showAvailableUpdate() {
        if let release = updates.available { presentUpdate(.available(release)) } else { checkForUpdates() }
    }
    @objc func checkForUpdates() {
        updates.checkNow { [weak self] outcome in self?.presentUpdate(outcome) }
    }

    private func presentUpdate(_ outcome: UpdateChecker.Outcome) {
        let alert = NSAlert()
        var page: URL?
        switch outcome {
        case .available(let release):
            alert.messageText = "Vidac \(release.version) is available"
            alert.informativeText =
                "You have Vidac \(UpdateChecker.runningVersion ?? "an older version"). The new version is on its release page. Vidac never downloads or installs updates by itself."
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Later")
            page = release.page
            player?.dismissUpdateNotice()
        case .upToDate:
            alert.messageText = "Vidac is up to date"
            alert.informativeText = "You have the latest version, \(UpdateChecker.runningVersion ?? "")."
            alert.addButton(withTitle: "OK")
        case .failed:
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = "Vidac couldn’t reach GitHub. Check your internet connection and try again."
            alert.addButton(withTitle: "OK")
        }
        present(alert) { response in
            if response == .alertFirstButtonReturn, let page { NSWorkspace.shared.open(page) }
        }
    }
}
