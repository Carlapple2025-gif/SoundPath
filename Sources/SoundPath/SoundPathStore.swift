import AppKit
import CoreAudio
import Foundation
import SwiftUI

@MainActor
final class SoundPathStore: ObservableObject {
    struct ActiveRoute {
        let deviceID: AudioDeviceID
        let deviceName: String
        let router: AppAudioRouter
    }

    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var defaultOutputID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    @Published private(set) var apps: [AppAudioGroup] = []
    @Published private(set) var routes: [String: ActiveRoute] = [:]
    /// Hardware volume per output device (0…1). Control Center only exposes a
    /// slider for the default output, so this is what makes every other output
    /// adjustable from the panel.
    @Published private(set) var deviceVolumes: [AudioDeviceID: Float] = [:]
    /// Software gain per routed app (0…1.5). `routeGains` only holds apps that
    /// are currently routed; the value also survives a restart in UserDefaults.
    @Published private(set) var routeGains: [String: Float] = [:]
    @Published var errorMessage: String?

    private let deviceCenter = AudioDeviceCenter()
    private var volumeControls: [AudioDeviceID: OutputVolumeControl] = [:]
    private var lastVolumeWrite: [AudioDeviceID: Date] = [:]
    private var tonePlayer: TestTonePlayer?
    private var refreshTimer: Timer?
    private var isStarted = false
    private var isRefreshing = false

    var defaultDevice: AudioOutputDevice? {
        devices.first { $0.id == defaultOutputID }
    }

    var routeCount: Int { routes.count }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if routes.isEmpty {
            deviceCenter.removeStaleManagedDevices()
        }
        refresh()

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try deviceCenter.refresh()
            devices = deviceCenter.devices
            defaultOutputID = deviceCenter.defaultOutputID
            volumeControls = deviceCenter.volumeControls
        } catch {
            return
        }

        refreshHardwareVolumes()

        let newApps = (try? AudioProcessScanner.scan()) ?? []

        // Stop routes whose app vanished or whose target device was unplugged.
        for (appID, route) in routes {
            let appStillThere = newApps.contains { $0.id == appID }
            let deviceStillThere = devices.contains { $0.id == route.deviceID }
            if !appStillThere || !deviceStillThere {
                route.router.stop()
                routes.removeValue(forKey: appID)
                routeGains.removeValue(forKey: appID)
            }
        }

        apps = newApps
    }

    // MARK: - Output volume

    func hardwareVolume(_ device: AudioOutputDevice) -> Float? {
        deviceVolumes[device.id]
    }

    func setHardwareVolume(_ device: AudioOutputDevice, _ value: Float) {
        guard let control = volumeControls[device.id], control.isSupported else { return }
        let clamped = min(1, max(0, value))
        do {
            try control.write(clamped)
            deviceVolumes[device.id] = clamped
            lastVolumeWrite[device.id] = Date()
        } catch {
            errorMessage = friendly(error)
        }
    }

    private func refreshHardwareVolumes() {
        let now = Date()
        var volumes: [AudioDeviceID: Float] = [:]
        for device in devices {
            guard let control = volumeControls[device.id], control.isSupported else { continue }
            // Don't fight the user's finger while a slider is being dragged.
            if let last = lastVolumeWrite[device.id],
               now.timeIntervalSince(last) < 1.5,
               let cached = deviceVolumes[device.id] {
                volumes[device.id] = cached
                continue
            }
            if let value = control.read() {
                volumes[device.id] = value
            }
        }

        guard volumes != deviceVolumes else { return }
        deviceVolumes = volumes
    }

    // MARK: - Per-route software gain

    func routeGain(for appID: String) -> Float {
        routeGains[appID] ?? Self.storedGain(for: appID)
    }

    func setRouteGain(_ value: Float, for appID: String) {
        let clamped = min(1.5, max(0, value))
        routes[appID]?.router.setVolume(clamped)
        routeGains[appID] = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.gainKey(appID))
    }

    private static func gainKey(_ appID: String) -> String {
        "routeGain.\(appID)"
    }

    private static func storedGain(for appID: String) -> Float {
        guard UserDefaults.standard.object(forKey: gainKey(appID)) != nil else { return 1 }
        return min(1.5, max(0, Float(UserDefaults.standard.double(forKey: gainKey(appID)))))
    }

    func setDefaultOutput(_ device: AudioOutputDevice) {
        do {
            try deviceCenter.setDefault(device)
            devices = deviceCenter.devices
            // Switching to AirPlay can take a moment; show the choice right away.
            defaultOutputID = device.id

            // An app that follows the system no longer needs its own route.
            for (appID, route) in routes where route.deviceID == device.id {
                route.router.stop()
                routes.removeValue(forKey: appID)
                routeGains.removeValue(forKey: appID)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.refresh()
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    func effectiveDeviceID(for app: AppAudioGroup) -> AudioDeviceID? {
        routes[app.id]?.deviceID
    }

    func selectTarget(for app: AppAudioGroup, deviceID: AudioDeviceID) {
        errorMessage = nil

        // 0 means "follow the system output".
        if deviceID == 0 || deviceID == defaultOutputID {
            stopRoute(appID: app.id)
            return
        }

        guard let device = devices.first(where: { $0.id == deviceID }) else { return }

        if device.isAirPlay {
            errorMessage = "AirPlay（HomePod）不能作为单个 App 的输出：系统不允许它参与分应用音频路由。可以把整个系统输出切到 AirPlay，再只把 Chrome 这类 App 单独放到耳机上。"
            return
        }

        stopRoute(appID: app.id)

        guard !app.processObjectIDs.isEmpty else {
            errorMessage = "这个 App 现在没有可接管的音频进程，先让它播放一点声音再试。"
            return
        }

        let router = AppAudioRouter(
            appID: app.id,
            appName: app.name,
            processObjectIDs: app.processObjectIDs,
            targetDeviceID: device.id,
            targetDeviceName: device.name,
            targetDeviceUID: device.uid,
            volume: Self.storedGain(for: app.id)
        )

        do {
            try router.start()
            routes[app.id] = ActiveRoute(deviceID: device.id, deviceName: device.name, router: router)
            routeGains[app.id] = Self.storedGain(for: app.id)
        } catch {
            errorMessage = friendly(error)
        }
    }

    func stopRoute(appID: String) {
        guard let route = routes[appID] else { return }
        route.router.stop()
        routes.removeValue(forKey: appID)
        routeGains.removeValue(forKey: appID)
    }

    func stopAllRoutes() {
        for route in routes.values {
            route.router.stop()
        }
        routes.removeAll()
        routeGains.removeAll()
    }

    func playTestTone(_ device: AudioOutputDevice) {
        guard !device.isAirPlay else {
            errorMessage = "AirPlay 有 1–2 秒延迟，试听音不适合用来判断位置；请在控制中心确认 HomePod 是否已连接。"
            return
        }

        errorMessage = nil
        tonePlayer?.stop()

        let player = TestTonePlayer()
        do {
            try player.start(deviceUID: device.uid, duration: 1.0)
            tonePlayer = player
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self, weak player] in
                player?.stop()
                if let player, self?.tonePlayer === player {
                    self?.tonePlayer = nil
                }
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    private func friendly(_ error: Error) -> String {
        let detail = error.localizedDescription
        return detail + "。若这是第一次启用，请在系统弹窗里点「允许」；若曾拒绝，请到 系统设置 → 隐私与安全性 → 屏幕与系统音频录制 中打开「声路」，然后重试。"
    }
}
