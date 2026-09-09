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
                    if controller.captureSource == .display {
                        displayPicker
                    } else {
                        windowPicker
                    }
                    Divider()
                    cameraRow
                    micRow
                    Toggle("Record system audio", isOn: $controller.enableSystemAudio)
                        .disabled(controller.isRecording)
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
                    Picker("Frame rate", selection: $controller.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .disabled(controller.isRecording)
                    Picker("Resolution", selection: $controller.captureScale) {
                        ForEach(CaptureScale.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(controller.isRecording)

                    Divider()

                    Toggle("Compress with FFmpeg", isOn: $controller.compressOutput)
                        .disabled(controller.isRecording || controller.isCompressing)
                    if controller.compressOutput {
                        Picker("Quality", selection: $controller.compressionQuality) {
                            ForEach(FFmpegCompressor.Quality.allCases) { q in
                                Text(q.rawValue).tag(q)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(controller.isRecording || controller.isCompressing)
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

    // MARK: - Pickers

    private var captureSourcePicker: some View {
        Picker("Capture", selection: $controller.captureSource) {
            ForEach(CaptureSource.allCases) { source in
                Text(source.rawValue).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .disabled(controller.isRecording)
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

    private var cameraRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Webcam", isOn: $controller.enableCamera)
                    .disabled(controller.isRecording)
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $controller.selectedCameraID) {
                    ForEach(controller.cameras, id: \.uniqueID) { c in
                        Text(c.localizedName).tag(Optional(c.uniqueID))
                    }
                }
                .labelsHidden()
                .disabled(controller.isRecording || !controller.enableCamera)
            }
            if controller.enableCamera {
                HStack {
                    Text("Camera size")
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
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
        HStack {
            Toggle("Microphone", isOn: $controller.enableMicrophone)
                .disabled(controller.isRecording)
                .frame(width: 120, alignment: .leading)
            Picker("", selection: $controller.selectedMicID) {
                ForEach(controller.microphones, id: \.uniqueID) { m in
                    Text(m.localizedName).tag(Optional(m.uniqueID))
                }
            }
            .labelsHidden()
            .disabled(controller.isRecording || !controller.enableMicrophone)
        }
    }
}
