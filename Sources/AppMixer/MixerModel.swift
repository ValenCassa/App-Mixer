import AppKit
import CoreAudio
import Foundation

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var statusMessage = "Looking for apps using audio…"
    @Published private(set) var outputDeviceName = "System Output"
    @Published private(set) var masterVolume: Float = 1
    @Published private(set) var canControlMasterVolume = false
    @Published var showInactiveApps = true
    @Published var launchAtLogin = false
    @Published var searchText = ""

    private var routes: [String: ProcessAudioRoute] = [:]
    private var refreshTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var savedVolumes: [String: Float] = [:]
    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var outputDeviceUID = ""
    private var previousMasterVolume: Float = 0.5

    var visibleApps: [AudioApp] {
        let activityFiltered = showInactiveApps ? apps : apps.filter(\.isPlaying)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return activityFiltered }
        return activityFiltered.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var isAnyAppPlaying: Bool {
        apps.contains { $0.isPlaying && $0.level > 0.015 }
    }

    init() {
        loadPreferences()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.readLevels()
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        levelTask?.cancel()
        routes.values.forEach { $0.stop() }
    }

    func refresh() async {
        do {
            let system = AudioHardwareSystem.shared
            guard let output = try system.defaultOutputDevice else {
                statusMessage = "No output device is available"
                return
            }

            let newUID = try output.uid
            let newName = try output.name
            if output.id != outputDeviceID || newUID != outputDeviceUID {
                stopAllRoutes()
                outputDeviceID = output.id
                outputDeviceUID = newUID
                outputDeviceName = newName
            }
            syncMasterVolume()

            let ownPID = ProcessInfo.processInfo.processIdentifier
            let processes = try system.processes.compactMap { process -> ProcessSnapshot? in
                guard let pid = try? process.pid,
                      pid != ownPID,
                      let bundleID = try? process.bundleID,
                      !bundleID.isEmpty,
                      let identity = applicationIdentity(for: pid, reportedBundleID: bundleID) else {
                    return nil
                }

                let isRunning = (try? process.isRunningOutput) ?? false
                return ProcessSnapshot(
                    objectID: process.id,
                    appBundleID: identity.bundleID,
                    appName: identity.name,
                    appIcon: identity.icon,
                    isPlaying: isRunning
                )
            }

            var groupsByBundleID = Dictionary(grouping: processes, by: \.appBundleID)
                .mapValues { processes in
                    AppProcessGroup(
                        bundleID: processes[0].appBundleID,
                        name: processes[0].appName,
                        icon: processes[0].appIcon,
                        processObjectIDs: processes.map(\.objectID),
                        isPlaying: processes.contains(where: \.isPlaying)
                    )
                }

            // Core Audio only reports a process after it has connected to an
            // audio device. Add every open user-facing app as well, allowing
            // silent apps to appear before their first sound.
            for runningApp in NSWorkspace.shared.runningApplications {
                guard runningApp.processIdentifier != ownPID,
                      runningApp.activationPolicy != .prohibited,
                      let reportedBundleID = runningApp.bundleIdentifier,
                      let identity = applicationIdentity(
                          for: runningApp.processIdentifier,
                          reportedBundleID: reportedBundleID
                      ),
                      groupsByBundleID[identity.bundleID] == nil else {
                    continue
                }
                groupsByBundleID[identity.bundleID] = AppProcessGroup(
                    bundleID: identity.bundleID,
                    name: identity.name,
                    icon: identity.icon,
                    processObjectIDs: [],
                    isPlaying: false
                )
            }

            let appGroups = groupsByBundleID.values
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            let liveBundleIDs = Set(appGroups.map(\.bundleID))
            for (bundleID, route) in routes where !liveBundleIDs.contains(bundleID) {
                route.stop()
                routes.removeValue(forKey: bundleID)
            }

            var nextApps: [AudioApp] = []
            for item in appGroups {
                let name = item.name
                let key = item.bundleID
                let existing = apps.first(where: { $0.bundleID == key })
                let volume = existing?.volume ?? savedVolumes[key] ?? 1
                let muted = existing?.isMuted ?? false

                let routedProcessIDs = routes[key]?.processObjectIDs ?? []
                if item.processObjectIDs.isEmpty {
                    routes[key]?.stop()
                    routes.removeValue(forKey: key)
                } else if routes[key] == nil || Set(routedProcessIDs) != Set(item.processObjectIDs) {
                    routes[key]?.stop()
                    do {
                        let route = try ProcessAudioRoute(
                            processObjectIDs: item.processObjectIDs,
                            processName: name,
                            outputDeviceUID: outputDeviceUID,
                            volume: muted ? 0 : volume
                        )
                        routes[key] = route
                    } catch {
                        routes.removeValue(forKey: key)
                        // Keep the app visible. Permission denial and unsupported streams
                        // are surfaced in the footer instead of hiding the process.
                    }
                }

                let route = routes[key]
                nextApps.append(AudioApp(
                    id: key,
                    processObjectIDs: item.processObjectIDs,
                    bundleID: item.bundleID,
                    name: name,
                    icon: item.icon,
                    volume: volume,
                    isMuted: muted,
                    isPlaying: item.isPlaying,
                    level: route?.displayLevel ?? 0,
                    isRouted: route != nil
                ))
            }

            apps = nextApps
            if apps.isEmpty {
                statusMessage = "Play audio in an app and it will appear here"
            } else if appGroups.contains(where: { !$0.processObjectIDs.isEmpty }) && routes.isEmpty {
                statusMessage = "Allow System Audio Recording to enable mixing"
            } else {
                let count = apps.filter(\.isPlaying).count
                statusMessage = count == 0 ? "No apps are playing right now" : "Mixing \(count) active \(count == 1 ? "app" : "apps")"
            }
        } catch {
            statusMessage = "Core Audio: \(error.localizedDescription)"
        }
    }

    func setVolume(_ value: Double, for id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        let volume = Float(max(0, min(1, value)))
        apps[index].volume = volume
        if volume > 0 { apps[index].isMuted = false }
        routes[id]?.volume = apps[index].isMuted ? 0 : volume
        savedVolumes[apps[index].bundleID] = volume
        saveVolumes()
    }

    func toggleMute(for id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[index].isMuted.toggle()
        routes[id]?.volume = apps[index].isMuted ? 0 : apps[index].volume
    }

    func resetVolumes() {
        savedVolumes.removeAll()
        for index in apps.indices {
            apps[index].volume = 1
            apps[index].isMuted = false
            routes[apps[index].id]?.volume = 1
        }
        saveVolumes()
    }

    func setMasterVolume(_ value: Double) {
        guard outputDeviceID != kAudioObjectUnknown else { return }
        let volume = Float(max(0, min(1, value)))
        if Self.writeMasterVolume(volume, to: outputDeviceID) {
            masterVolume = volume
            if volume > 0.001 { previousMasterVolume = volume }
            canControlMasterVolume = true
        } else {
            canControlMasterVolume = false
            statusMessage = "This output device does not expose a software volume control"
        }
    }

    func toggleMasterMute() {
        if masterVolume > 0.001 {
            previousMasterVolume = masterVolume
            setMasterVolume(0)
        } else {
            setMasterVolume(Double(max(0.1, previousMasterVolume)))
        }
    }

    func retryAudioAccess() {
        stopAllRoutes()
        Task { await refresh() }
    }

    private func readLevels() {
        for index in apps.indices {
            let raw = routes[apps[index].id]?.displayLevel ?? 0
            let falling = apps[index].level * 0.72
            apps[index].level = max(raw, falling)
        }
    }

    private func stopAllRoutes() {
        routes.values.forEach { $0.stop() }
        routes.removeAll()
    }

    private func syncMasterVolume() {
        guard outputDeviceID != kAudioObjectUnknown else {
            canControlMasterVolume = false
            return
        }
        if let value = Self.readMasterVolume(from: outputDeviceID) {
            masterVolume = value
            canControlMasterVolume = true
        } else {
            canControlMasterVolume = false
        }
    }

    private static func readMasterVolume(from deviceID: AudioObjectID) -> Float? {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: AudioObjectPropertyElement(element)
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                return max(0, min(1, value))
            }
        }
        return nil
    }

    @discardableResult
    private static func writeMasterVolume(_ volume: Float, to deviceID: AudioObjectID) -> Bool {
        var wroteValue = false
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: AudioObjectPropertyElement(element)
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }

            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
                  settable.boolValue else { continue }

            var value = volume
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float>.size),
                &value
            )
            if status == noErr { wroteValue = true }

            // A settable main element controls all channels, so channel writes
            // are unnecessary and can cause visible slider jitter.
            if element == kAudioObjectPropertyElementMain, wroteValue { break }
        }
        return wroteValue
    }

    /// Returns a user-facing application identity for a Core Audio process.
    /// Daemons have no enclosing `.app` and are intentionally excluded. Helper
    /// processes use the outermost enclosing app so Chrome Helper becomes Chrome.
    private func applicationIdentity(for pid: pid_t, reportedBundleID: String) -> ApplicationIdentity? {
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else { return nil }

        let candidatePath = runningApp.executableURL?.path ?? runningApp.bundleURL?.path
        guard let candidatePath,
              let appURL = outermostApplicationURL(in: candidatePath),
              let bundle = Bundle(url: appURL),
              let appBundleID = bundle.bundleIdentifier,
              appBundleID != Bundle.main.bundleIdentifier else {
            return nil
        }

        // CoreServices and PrivateFrameworks contain app-shaped system UI and
        // daemon bundles (Control Center, conferencing helpers, speech services,
        // and similar). They are audio clients, but not applications a person
        // can meaningfully mix.
        let appPath = appURL.standardizedFileURL.path
        let systemServiceRoots = [
            "/System/Library/",
            "/Library/Apple/System/"
        ]
        guard !systemServiceRoots.contains(where: appPath.hasPrefix) else { return nil }

        // A few macOS services are packaged as .app bundles despite having no
        // user-facing UI. Require a regular or accessory parent application.
        let hasVisibleParent = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == appBundleID && $0.activationPolicy != .prohibited
        }
        guard hasVisibleParent else { return nil }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")

        return ApplicationIdentity(
            bundleID: appBundleID.isEmpty ? reportedBundleID : appBundleID,
            name: displayName,
            icon: NSWorkspace.shared.icon(forFile: appURL.path)
        )
    }

    private func outermostApplicationURL(in path: String) -> URL? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        var current = ""
        for component in components {
            if component == "/" {
                current = "/"
            } else {
                current = (current as NSString).appendingPathComponent(component)
            }
            if component.lowercased().hasSuffix(".app") {
                return URL(fileURLWithPath: current, isDirectory: true)
            }
        }
        return nil
    }

    private func loadPreferences() {
        guard let values = UserDefaults.standard.dictionary(forKey: "appVolumes") as? [String: Double] else { return }
        savedVolumes = values.mapValues(Float.init)
    }

    private func saveVolumes() {
        UserDefaults.standard.set(savedVolumes.mapValues(Double.init), forKey: "appVolumes")
    }
}

struct AudioApp: Identifiable {
    let id: String
    let processObjectIDs: [AudioObjectID]
    let bundleID: String
    let name: String
    let icon: NSImage
    var volume: Float
    var isMuted: Bool
    var isPlaying: Bool
    var level: Float
    var isRouted: Bool
}

private struct ProcessSnapshot {
    let objectID: AudioObjectID
    let appBundleID: String
    let appName: String
    let appIcon: NSImage
    let isPlaying: Bool
}

private struct AppProcessGroup {
    let bundleID: String
    let name: String
    let icon: NSImage
    let processObjectIDs: [AudioObjectID]
    let isPlaying: Bool
}

private struct ApplicationIdentity {
    let bundleID: String
    let name: String
    let icon: NSImage
}
