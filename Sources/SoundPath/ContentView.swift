import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: SoundPathStore

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = store.errorMessage {
                errorBanner(error)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("系统输出", systemImage: "speaker.wave.2", note: "全部 App")
                    systemOutputList

                    sectionTitle("应用声音", systemImage: "square.stack.3d.up", note: "只改单个 App")
                    appList
                }
                .padding(12)
            }
            .frame(height: 396)
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { store.start() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color(red: 0.24, green: 0.72, blue: 0.86)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "hifispeaker.2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text("声路")
                    .font(.system(size: 14, weight: .semibold))
                Text("按 App 分配声音输出")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.routeCount > 0 {
                Text("接管中 \(store.routeCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.13), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                store.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(9)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Sections

    private func sectionTitle(_ title: String, systemImage: String, note: String? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
            if let note {
                Spacer()
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 2)
    }

    private var systemOutputList: some View {
        VStack(spacing: 2) {
            ForEach(store.devices) { device in
                HStack(spacing: 6) {
                    Button {
                        store.setDefaultOutput(device)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: device.symbolName)
                                .font(.system(size: 13))
                                .foregroundStyle(device.isAirPlay ? Color.purple : Color.primary)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 0) {
                                Text(device.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                if let subtitle = device.subtitle {
                                    Text(subtitle)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .lineLimit(1)
                            .truncationMode(.middle)

                            Spacer(minLength: 4)

                            if store.defaultOutputID == device.id {
                                Text("默认")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.leading, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    deviceVolumeControl(device)

                    Button {
                        store.playTestTone(device)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("试听这个输出")
                    .padding(.trailing, 8)
                }
                .background(
                    store.defaultOutputID == device.id ? Color.accentColor.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            }
        }
    }

    /// Volume of one physical output. Control Center only offers this for the
    /// default output, so every other device gets its slider here.
    @ViewBuilder
    private func deviceVolumeControl(_ device: AudioOutputDevice) -> some View {
        if let volume = store.hardwareVolume(device) {
            HStack(spacing: 3) {
                Image(systemName: volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(store.hardwareVolume(device) ?? volume) },
                        set: { store.setHardwareVolume(device, Float($0)) }
                    ),
                    in: 0...1
                )
                .controlSize(.mini)
                .frame(width: 62)
                .accessibilityLabel("\(device.name) 音量")
            }
            .help("这个出口的系统音量（控制中心只调默认出口）")
        } else {
            Image(systemName: "speaker.slash")
                .font(.system(size: 9))
                .foregroundStyle(Color.secondary.opacity(0.45))
                .help("这个出口没有可写的系统音量（常见于 HDMI 显示器），可用接管后 App 行的增益调小")
                .padding(.trailing, 2)
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.apps.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 11))
                    Text("还没有 App 在使用声音")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
            } else {
                ForEach(store.apps) { app in
                    appRow(app)
                }
            }
        }
    }

    private func appRow(_ app: AppAudioGroup) -> some View {
        HStack(spacing: 9) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(app.isPlaying ? "正在播放" : "空闲")
                        .font(.system(size: 9))
                        .foregroundStyle(app.isPlaying ? Color.green : Color.secondary)

                    if store.routes[app.id] != nil {
                        routeGainControl(app)
                    }
                }
            }

            Spacer(minLength: 6)

            targetMenu(app)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Software gain of one routed app, so a single output can still be mixed
    /// per app — and outputs without a writable system volume remain adjustable.
    private func routeGainControl(_ app: AppAudioGroup) -> some View {
        let gain = store.routeGain(for: app.id)
        return HStack(spacing: 4) {
            Image(systemName: gain <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(store.routeGain(for: app.id)) },
                    set: { store.setRouteGain(Float($0), for: app.id) }
                ),
                in: 0...1.5
            )
            .controlSize(.mini)
            .frame(width: 76)
            .accessibilityLabel("\(app.name) 增益")
            .help("这一路声音的增益：100% 为原始音量，最高 150%")

            Text("\(Int((gain * 100).rounded()))%")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(gain == 1 ? Color.secondary : Color.accentColor)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func targetMenu(_ app: AppAudioGroup) -> some View {
        Menu {
            Button {
                store.selectTarget(for: app, deviceID: 0)
            } label: {
                if store.routes[app.id] == nil {
                    Label("跟随系统输出", systemImage: "checkmark")
                } else {
                    Text("跟随系统输出")
                }
            }

            Divider()

            ForEach(store.devices) { device in
                Button {
                    store.selectTarget(for: app, deviceID: device.id)
                } label: {
                    let name = device.id == store.defaultOutputID
                        ? "\(device.name)（系统默认）"
                        : device.name
                    if store.routes[app.id]?.deviceID == device.id {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
                .disabled(device.isAirPlay)
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.routes[app.id]?.deviceName ?? "跟随系统")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(store.routes[app.id] == nil ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 118, alignment: .trailing)
            .background(
                (store.routes[app.id] == nil ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.12)),
                in: Capsule()
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.routeCount > 0 ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(store.routeCount > 0 ? "已接管 \(store.routeCount) 个 App" : "未接管任何 App")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("全部恢复") {
                    store.stopAllRoutes()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(store.routeCount == 0)

                Button("退出") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Text("▶ 试听；设备行滑杆调该出口音量（控制中心只调默认出口）；App 接管后可在其行内再调这一路增益。AirPlay 延迟 1–2 秒，游戏不建议。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .lineLimit(3)
        }
    }
}
