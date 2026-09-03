import AppKit
import SwiftUI

struct MixerView: View {
    @EnvironmentObject private var mixer: MixerModel

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.55)

            if mixer.visibleApps.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(mixer.visibleApps) { app in
                            AppVolumeRow(app: app)
                                .environmentObject(mixer)
                        }
                    }
                    .padding(12)
                }
                .frame(minHeight: 250, maxHeight: 470)
            }

            Divider().opacity(0.55)
            footer
        }
        .frame(width: 410)
        .background(.ultraThinMaterial)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search apps", text: $mixer.searchText)
                .textFieldStyle(.plain)

            if !mixer.searchText.isEmpty {
                Button {
                    mixer.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.065))
        )
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: mixer.searchText.isEmpty ? "waveform.slash" : "magnifyingglass")
                .font(.system(size: 33, weight: .light))
                .foregroundStyle(.secondary)
            Text(mixer.searchText.isEmpty ? "No audio apps yet" : "No matching apps")
                .font(.headline)
            Text(mixer.searchText.isEmpty
                 ? "Start playing something in Music, Safari, Spotify, or another app."
                 : "Try a different application name.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button(mixer.searchText.isEmpty ? "Check Again" : "Clear Search") {
                if mixer.searchText.isEmpty {
                    Task { await mixer.refresh() }
                } else {
                    mixer.searchText = ""
                }
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding()
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 25, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(mixer.outputDeviceName)
                            .font(.system(size: 13.5, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(mixer.masterVolume * 100))%")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    HStack(spacing: 9) {
                        Button {
                            mixer.toggleMasterMute()
                        } label: {
                            Image(systemName: masterSpeakerSymbol)
                                .frame(width: 16)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(mixer.masterVolume <= 0.001 ? Color.red : Color.secondary)
                        .disabled(!mixer.canControlMasterVolume)

                        Slider(
                            value: Binding(
                                get: { Double(mixer.masterVolume) },
                                set: { mixer.setMasterVolume($0) }
                            ),
                            in: 0...1
                        )
                        .labelsHidden()
                        .disabled(!mixer.canControlMasterVolume)
                    }
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )

            HStack {
                Text(mixer.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("⌘Q to quit")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
        }
        .padding(12)
    }

    private var masterSpeakerSymbol: String {
        switch mixer.masterVolume {
        case ...0.001: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

private struct AppVolumeRow: View {
    @EnvironmentObject private var mixer: MixerModel
    let app: AudioApp

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(app.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(app.isMuted ? "Muted" : "\(Int(app.volume * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 9) {
                    Button {
                        mixer.toggleMute(for: app.id)
                    } label: {
                        Image(systemName: app.isMuted || app.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 16)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(app.isMuted ? Color.red : Color.secondary)

                    ZStack(alignment: .leading) {
                        LevelTrack(level: CGFloat(app.level), muted: app.isMuted)
                        Slider(
                            value: Binding(
                                get: { Double(app.volume) },
                                set: { mixer.setVolume($0, for: app.id) }
                            ),
                            in: 0...1
                        )
                        .labelsHidden()
                        .tint(.clear)
                        .opacity(0.82)
                    }
                    .frame(height: 16)
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .help(app.isRouted ? "Live audio route active" : "Waiting for audio permission or a supported output stream")
    }
}

private struct LevelTrack: View {
    let level: CGFloat
    let muted: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, min(proxy.size.width, proxy.size.width * level))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                Capsule()
                    .fill(muted ? AnyShapeStyle(Color.secondary.opacity(0.35)) : AnyShapeStyle(meterGradient))
                    .frame(width: width)
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 5)
        .allowsHitTesting(false)
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            colors: [.accentColor, .green, .yellow],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct SettingsView: View {
    @EnvironmentObject private var mixer: MixerModel

    var body: some View {
        Form {
            Toggle("Show apps that are connected to audio but currently silent", isOn: $mixer.showInactiveApps)
            LabeledContent("Audio output", value: mixer.outputDeviceName)
            HStack {
                Spacer()
                Button("Reset Saved Volumes") { mixer.resetVolumes() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 180)
        .padding()
    }
}
