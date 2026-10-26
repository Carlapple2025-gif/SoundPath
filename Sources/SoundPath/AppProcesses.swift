import AppKit
import CoreAudio
import Foundation

struct AppAudioGroup: Identifiable {
    let id: String
    let name: String
    let bundleID: String?
    let processObjectIDs: [AudioObjectID]
    let isPlaying: Bool
    let icon: NSImage?
}

extension AppAudioGroup: Hashable {
    static func == (lhs: AppAudioGroup, rhs: AppAudioGroup) -> Bool {
        lhs.id == rhs.id
            && lhs.isPlaying == rhs.isPlaying
            && lhs.processObjectIDs == rhs.processObjectIDs
            && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum AudioProcessScanner {
    /// Groups audio-capable processes by app (bundle id family) so Chrome and its
    /// helper processes can be tapped together. Chrome's actual audio runs in a
    /// helper process that is *not* a regular foreground app, so matching by
    /// bundle-id family (rather than activation policy) is essential.
    static func scan(excludingPID ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) throws -> [AppAudioGroup] {
        let objectIDs: [AudioObjectID] = try readArrayProperty(caSystemObject, kAudioHardwarePropertyProcessObjectList)

        let regularApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }

        var appsByFamily: [String: NSRunningApplication] = [:]
        for app in regularApps {
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { continue }
            appsByFamily[familyID(for: bundleID).lowercased()] = app
        }

        var buckets: [String: (name: String, bundleID: String?, ids: [AudioObjectID], playing: Bool, icon: NSImage?)] = [:]

        for objectID in objectIDs {
            let pid: pid_t = try readProperty(objectID, kAudioProcessPropertyPID, defaultValue: pid_t(-1))
            guard pid > 0, pid != ownPID else { continue }

            let bundleID = (try? readStringProperty(objectID, kAudioProcessPropertyBundleID)) ?? ""
            let playing = ((try? readProperty(objectID,
                                              kAudioProcessPropertyIsRunningOutput,
                                              defaultValue: UInt32(0))) ?? 0) == 1

            var family = "pid:\(pid)"
            var application: NSRunningApplication?

            if !bundleID.isEmpty {
                family = familyID(for: bundleID)
                application = appsByFamily[family.lowercased()]
            }

            // Fallback for processes whose own bundle id is missing or differs
            // from the app family: accept regular apps by pid.
            if application == nil,
               let running = NSRunningApplication(processIdentifier: pid),
               running.activationPolicy == .regular {
                application = running
                if let runningBundleID = running.bundleIdentifier, !runningBundleID.isEmpty {
                    family = familyID(for: runningBundleID)
                }
            }

            guard let application else { continue }

            let name = application.localizedName
                ?? bundleID.components(separatedBy: ".").last
                ?? "PID \(pid)"

            var bucket = buckets[family] ?? (
                name: name,
                bundleID: bundleID.isEmpty ? nil : bundleID,
                ids: [],
                playing: false,
                icon: application.icon
            )
            if bucket.icon == nil { bucket.icon = application.icon }
            if !bucket.ids.contains(objectID) { bucket.ids.append(objectID) }
            bucket.playing = bucket.playing || playing
            buckets[family] = bucket
        }

        return buckets.map { family, bucket in
            AppAudioGroup(
                id: family,
                name: bucket.name,
                bundleID: bucket.bundleID,
                processObjectIDs: bucket.ids.sorted(),
                isPlaying: bucket.playing,
                icon: bucket.icon
            )
        }
        .sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func familyID(for bundleID: String) -> String {
        let lowered = bundleID.lowercased()
        if let range = lowered.range(of: ".helper") {
            return String(bundleID[..<range.lowerBound])
        }
        return bundleID
    }
}
