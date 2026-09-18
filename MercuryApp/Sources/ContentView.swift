import SwiftUI
import ScreenCaptureKit

/// Configuration panel shown inside the toolbar's settings popover.
struct ContentView: View {
    @EnvironmentObject var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            GroupBox("Sources") {
                VStack(alignment: .leading, spacing: 12) {
                    captureSourcePicker
                    switch controller.captureSource {
                    case .display: displayPicker
                    case .window: windowPicker
                    case .phone: phonePicker
                    }
                    Divider()
                    cameraRow
                    micRow
                    HStack(spacing: 4) {
                        Toggle(controller.captureSource == .phone ? "Record iPhone audio" : "Record system audio",
                               isOn: $controller.enableSystemAudio)
                            .disabled(controller.isRecording)
                            .fixedSize()
                        helpHint(controller.captureSource == .phone
                                 ? "Capture the sound playing on the iPhone."
                                 : "Capture the sound playing from your Mac — apps, videos, music, alerts.")
                        Spacer()
                    }
                }
                .padding(6)
            }

            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(controller.outputFolder.path)
                            .lineLimit(1).truncationMode(.middle)
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { controller.chooseOutputFolder() }
                            .disabled(controller.isRecording)
                    }
                    HStack {
                        labelWithHint("Quality", "Recorded in real time by the Mac's hardware encoder — no waiting after you stop. Balanced matches Apple's screen recorder at a quarter of the size.")
                        Picker("", selection: $controller.recordingQuality) {
                            ForEach(RecordingQuality.allCases) { q in
                                Text(q.rawValue).tag(q)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(controller.isRecording)
                    }
                    Text(controller.recordingQuality.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 124)
                    HStack {
                        labelWithHint("Resolution", "1080p is what Loom and most screen recorders produce. 4K captures Retina detail so small text stays crisp, at roughly twice the size.")
                        Picker("", selection: $controller.captureScale) {
                            ForEach(CaptureScale.allCases) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(controller.isRecording || controller.captureSource == .phone)
                    }
                    Text(controller.captureSource == .phone
                         ? "iPhone recordings always use the phone's native resolution."
                         : controller.captureScale.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 124)

                    if controller.ffmpegAvailable {
                        Divider()

                        HStack(spacing: 4) {
                            Toggle("Extra compression (FFmpeg)", isOn: $controller.compressOutput)
                                .disabled(controller.isRecording || controller.isCompressing)
                                .fixedSize()
                            helpHint("Re-encode with x265 after you stop. Slightly smaller files, but it takes about as long as the recording itself. Usually not worth it.")
                            Spacer()
                        }
                        if controller.compressOutput {
                            HStack {
                                labelWithHint("Level", "Small = tiniest files, Quality = near-lossless.")
                                Picker("", selection: $controller.compressionQuality) {
                                    ForEach(FFmpegCompressor.Quality.allCases) { q in
                                        Text(q.rawValue).tag(q)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .disabled(controller.isRecording || controller.isCompressing)
                            }
                        }
                    }
                }
                .padding(6)
            }

            if controller.isRecording {
                Text(controller.status)
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
    }

    // MARK: - Help hint

    /// A small "?" icon that reveals a description instantly on hover.
    private func helpHint(_ text: String) -> some View {
        HelpHint(text: text)
    }

    /// Label + "?" hint sized to align trailing controls at a fixed width.
    private func labelWithHint(_ label: String, _ hint: String, width: CGFloat = 120) -> some View {
        HStack(spacing: 4) {
            Text(label)
            helpHint(hint)
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Pickers

    private var captureSourcePicker: some View {
        HStack {
            labelWithHint("Capture", "Record your entire display, a single window, or an iPhone connected by USB.")
            Picker("", selection: $controller.captureSource) {
                ForEach(CaptureSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(controller.isRecording)
        }
    }

    private var displayPicker: some View {
        Picker("Display", selection: $controller.selectedDisplayID) {
            ForEach(controller.displays, id: \.displayID) { d in
                Text("Display \(d.displayID) — \(d.width)×\(d.height)")
                    .tag(Optional(d.displayID))
            }
        }
        .disabled(controller.isRecording)
    }

    private var windowPicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .foregroundStyle(.secondary)
            Text(controller.pickedWindowName ?? "No window selected")
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(controller.pickedWindowName == nil ? .secondary : .primary)
            Spacer()
            Button(controller.pickedWindowName == nil ? "Choose Window…" : "Change…") {
                Task { await controller.chooseWindow() }
            }
            .disabled(controller.isRecording)
        }
    }

    private var phonePicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            if controller.phones.isEmpty {
                Text("No iPhone found. Connect it with a cable, unlock it, and tap Trust.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Refresh") { controller.refreshPhones() }
            } else {
                Picker("", selection: $controller.selectedPhoneID) {
                    ForEach(controller.phones, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(Optional(d.uniqueID))
                    }
                }
                .labelsHidden()
                .disabled(controller.isRecording)
            }
        }
    }

    private var cameraRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Toggle("Webcam", isOn: $controller.enableCamera)
                    .disabled(controller.isRecording)
                    .fixedSize()
                helpHint("Overlay your camera as a floating bubble in the recording. A live self-view appears on screen while it's on.")
                Spacer(minLength: 8)
                Picker("", selection: $controller.selectedCameraID) {
                    ForEach(controller.cameras, id: \.uniqueID) { c in
                        Text(c.localizedName).tag(Optional(c.uniqueID))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
                .disabled(controller.isRecording || !controller.enableCamera)
            }
            if controller.enableCamera {
                HStack {
                    labelWithHint("Camera size", "How large the camera bubble appears in the recording.")
                    Picker("", selection: $controller.cameraWidthFraction) {
                        Text("S").tag(CGFloat(0.10))
                        Text("M").tag(CGFloat(0.13))
                        Text("L").tag(CGFloat(0.20))
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(controller.isRecording)
                }
            }
        }
    }

    private var micRow: some View {
        HStack(spacing: 4) {
            Toggle("Microphone", isOn: $controller.enableMicrophone)
                .disabled(controller.isRecording)
                .fixedSize()
            helpHint("Record your voice from the selected input device.")
            Spacer(minLength: 8)
            Picker("", selection: $controller.selectedMicID) {
                ForEach(controller.microphones, id: \.uniqueID) { m in
                    Text(m.localizedName).tag(Optional(m.uniqueID))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 190)
            .disabled(controller.isRecording || !controller.enableMicrophone)
        }
    }
}

// MARK: - Instant help hint

/// A "?" icon that shows its description in a popover the moment you hover it —
/// unlike the native `.help()` tooltip, which has a multi-second delay.
private struct HelpHint: View {
    let text: String
    @State private var show = false

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(show ? Color.accentColor : .secondary)
            .onHover { show = $0 }
            .popover(isPresented: $show, arrowEdge: .top) {
                Text(text)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 220, alignment: .leading)
                    .padding(12)
                    .preferredColorScheme(.dark)
            }
    }
}
