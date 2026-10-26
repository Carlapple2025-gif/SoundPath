import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

@main
struct SoundPathLauncher {
    static func main() {
        let arguments = CommandLine.arguments

        if let snapshotIndex = arguments.firstIndex(of: "--snapshot"),
           snapshotIndex + 1 < arguments.count {
            _ = NSApplication.shared
            MainActor.assumeIsolated {
                SnapshotRenderer.writeWindow(
                    to: arguments[snapshotIndex + 1],
                    routeApp: snapshotIndex + 2 < arguments.count ? arguments[snapshotIndex + 2] : nil,
                    routeDevice: snapshotIndex + 3 < arguments.count ? arguments[snapshotIndex + 3] : nil
                )
            }
            return
        }

        if let testIndex = arguments.firstIndex(of: "--route-test"),
           testIndex + 2 < arguments.count {
            _ = NSApplication.shared
            let hold = testIndex + 3 < arguments.count ? (Double(arguments[testIndex + 3]) ?? 2.0) : 2.0
            let gain = testIndex + 4 < arguments.count ? Float(arguments[testIndex + 4]) : nil
            MainActor.assumeIsolated {
                RouteTester.run(appName: arguments[testIndex + 1],
                                deviceName: arguments[testIndex + 2],
                                holdSeconds: hold,
                                gain: gain)
            }
            return
        }

        if let toneIndex = arguments.firstIndex(of: "--tone-test"),
           toneIndex + 1 < arguments.count {
            _ = NSApplication.shared
            MainActor.assumeIsolated {
                let store = SoundPathStore()
                store.start()
                guard let device = store.devices.first(where: { $0.name == arguments[toneIndex + 1] }) else {
                    print("device not found:")
                    store.devices.forEach { print(" - \($0.name)") }
                    exit(2)
                }
                store.playTestTone(device)
                print("tone device=\(device.name) uid=\(device.uid) error=\(store.errorMessage ?? "none")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { exit(0) }
                RunLoop.main.run()
            }
            return
        }

        if arguments.contains("--mixer-test") {
            MixerTester.run()
            return
        }

        if arguments.contains("--preview") {
            PreviewApp.main()
        } else {
            SoundPathApp.main()
        }
    }
}

struct SoundPathApp: App {
    @StateObject private var store = SoundPathStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            Image(systemName: store.routeCount > 0 ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Used by `--preview` to open the same panel as a normal window.
struct PreviewApp: App {
    @StateObject private var store = SoundPathStore()

    var body: some Scene {
        WindowGroup("声路") {
            ContentView(store: store)
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

@MainActor
enum SnapshotRenderer {
    static func writeWindow(to path: String, routeApp: String? = nil, routeDevice: String? = nil) {
        let store = SoundPathStore()
        store.start()

        if let routeApp, let routeDevice,
           let app = store.apps.first(where: { $0.name.localizedCaseInsensitiveContains(routeApp) }),
           let device = store.devices.first(where: { $0.name == routeDevice }) {
            store.selectTarget(for: app, deviceID: device.id)
            if let error = store.errorMessage { print("route error: \(error)") }
        }

        let hosting = NSHostingView(rootView: ContentView(store: store).frame(width: 380).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 620),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        window.setContentSize(NSSize(width: 380, height: 620))
        window.center()
        window.orderFrontRegardless()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let contentView = window.contentView else {
                NSApp.terminate(nil)
                return
            }
            let bounds = contentView.bounds
            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                NSApp.terminate(nil)
                return
            }
            contentView.cacheDisplay(in: bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("snapshot written: \(path)")
            }
            NSApp.terminate(nil)
        }

        NSApp.run()
    }
}


@MainActor
enum RouteTester {
    static func run(appName: String, deviceName: String, holdSeconds: Double = 2.0, gain: Float? = nil) {
        let store = SoundPathStore()
        store.refresh()

        guard let app = store.apps.first(where: { $0.name.localizedCaseInsensitiveContains(appName) }) else {
            print("app not found. available apps:")
            store.apps.forEach { print(" - \($0.name) (\($0.id)) playing=\($0.isPlaying)") }
            exit(2)
        }
        guard let device = store.devices.first(where: { $0.name == deviceName }) else {
            print("device not found. available devices:")
            store.devices.forEach { print(" - \($0.name) id=\($0.id) airplay=\($0.isAirPlay)") }
            exit(2)
        }

        print("routing \(app.name) -> \(device.name) id=\(device.id) uid=\(device.uid) transport=\(device.transport)")
        print("app group: id=\(app.id) playing=\(app.isPlaying) processes=\(app.processObjectIDs.count)")
        store.selectTarget(for: app, deviceID: device.id)

        if let error = store.errorMessage {
            print("route failed: \(error)")
            exit(1)
        }
        if let gain {
            store.setRouteGain(gain, for: app.id)
            print("route gain=\(store.routeGain(for: app.id))")
        }
        print("route started (isRunning=\(store.routes[app.id]?.router.isRunning == true))")
        let center = AudioDeviceCenter()
        try? center.refresh()
        for device in center.devices {
            print("  device id=\(device.id) name=[\(device.name)] transport=\(device.transport) uid=[\(device.uid)]")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let running = (try? readProperty(device.id,
                                             kAudioDevicePropertyDeviceIsRunning,
                                             defaultValue: UInt32(0))) ?? 0
            let stats = store.routes[app.id]?.router.debugSummary ?? "no router"
            print("target device running=\(running) \(stats)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) {
            print("after \(holdSeconds)s still routed: \(store.routes[app.id] != nil)")
            store.stopAllRoutes()
            print("stopped, cleanup done")
            exit(0)
        }

        RunLoop.main.run()
    }
}

/// Verifies the route gain math (flat gain, ramped gain, channel fan-out,
/// clipping) without needing audio capture permission.
@MainActor
enum MixerTester {
    static func run() {
        var failures: [String] = []
        let frames = 256

        do { // 1. Flat 0.5 gain, identical interleaved stereo layouts.
            let source = BufferList(frames: frames, channels: 2, interleaved: true)
            let destination = BufferList(frames: frames, channels: 2, interleaved: true)
            source.fill { _, frame in Float(frame) * 0.001 }
            let gain = RouteGain(0.5)
            AppAudioRouter.copyAudio(source.pointer, destination.mutablePointer, gain: gain)
            for frame in 0..<frames {
                for channel in 0..<2 {
                    let expected = Float(frame) * 0.001 * 0.5
                    let actual = destination[frame, channel]
                    if abs(actual - expected) > 0.000001 {
                        failures.append("flat gain mismatch frame=\(frame) ch=\(channel) got=\(actual) want=\(expected)")
                        break
                    }
                }
            }
        }

        do { // 2. Ramped gain after a live slider change.
            let source = BufferList(frames: frames, channels: 2, interleaved: true)
            let destination = BufferList(frames: frames, channels: 2, interleaved: true)
            source.fill { _, frame in Float(frame) * 0.001 }
            let gain = RouteGain(1.0)
            gain.set(0.5)
            AppAudioRouter.copyAudio(source.pointer, destination.mutablePointer, gain: gain)
            for frame in 0..<frames {
                let ramp = 1.0 + (0.5 - 1.0) * Float(frame + 1) / Float(frames)
                let expected = Float(frame) * 0.001 * ramp
                let actual = destination[frame, 0]
                if abs(actual - expected) > 0.000001 {
                    failures.append("ramp mismatch frame=\(frame) got=\(actual) want=\(expected)")
                    break
                }
            }
            if abs(gain.step().from - 0.5) > 0.0001 {
                failures.append("gain did not settle at 0.5 after ramp")
            }
        }

        do { // 3. Mono source fanned out to interleaved stereo, unity gain.
            let source = BufferList(frames: frames, channels: 1, interleaved: false)
            let destination = BufferList(frames: frames, channels: 2, interleaved: true)
            source.fill { _, frame in Float(frame) * 0.002 }
            AppAudioRouter.copyAudio(source.pointer, destination.mutablePointer, gain: RouteGain(1))
            for frame in 0..<frames {
                let expected = Float(frame) * 0.002
                for channel in 0..<2 where abs(destination[frame, channel] - expected) > 0.000001 {
                    failures.append("fan-out mismatch frame=\(frame) ch=\(channel)")
                    break
                }
            }
        }

        do { // 4. 150% gain clips instead of wrapping.
            let source = BufferList(frames: 8, channels: 2, interleaved: true)
            let destination = BufferList(frames: 8, channels: 2, interleaved: true)
            source.fill { _, _ in 0.9 }
            AppAudioRouter.copyAudio(source.pointer, destination.mutablePointer, gain: RouteGain(1.5))
            for frame in 0..<8 where abs(destination[frame, 0] - 1.0) > 0.000001 {
                failures.append("clip mismatch frame=\(frame) got=\(destination[frame, 0]) want=1.0")
                break
            }
        }

        if failures.isEmpty {
            print("mixer test PASS (4 cases, \(frames) frames)")
            exit(0)
        }
        failures.forEach { print("mixer test FAIL: \($0)") }
        exit(1)
    }

    /// Small AudioBufferList owner used by the self-test.
    private final class BufferList {
        let frames: Int
        let channels: Int
        let bufferList: UnsafeMutableAudioBufferListPointer
        private var samples: [UnsafeMutablePointer<Float>] = []

        init(frames: Int, channels: Int, interleaved: Bool) {
            self.frames = frames
            self.channels = channels
            let bufferCount = interleaved ? 1 : channels
            bufferList = AudioBufferList.allocate(maximumBuffers: bufferCount)
            for index in 0..<bufferCount {
                let channelCount = interleaved ? channels : 1
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames * channelCount)
                pointer.initialize(repeating: 0, count: frames * channelCount)
                samples.append(pointer)
                bufferList[index] = AudioBuffer(
                    mNumberChannels: UInt32(channelCount),
                    mDataByteSize: UInt32(frames * channelCount * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(pointer)
                )
            }
        }

        deinit {
            samples.forEach { $0.deallocate() }
            free(bufferList.unsafeMutablePointer)
        }

        var pointer: UnsafePointer<AudioBufferList> {
            UnsafePointer(bufferList.unsafeMutablePointer)
        }

        var mutablePointer: UnsafeMutablePointer<AudioBufferList> {
            bufferList.unsafeMutablePointer
        }

        subscript(frame: Int, channel: Int) -> Float {
            let interleaved = bufferList.count == 1
            if interleaved {
                return samples[0][frame * channels + channel]
            }
            return samples[channel][frame]
        }

        func fill(_ value: (_ channel: Int, _ frame: Int) -> Float) {
            let interleaved = bufferList.count == 1
            for channel in 0..<channels {
                for frame in 0..<frames {
                    let sample = value(channel, frame)
                    if interleaved {
                        samples[0][frame * channels + channel] = sample
                    } else {
                        samples[channel][frame] = sample
                    }
                }
            }
        }
    }
}
