import SwiftUI

// MARK: - Button frame preference key

/// Collects each button's frame in SwiftUI's .global coordinate space so the
/// TooltipController can position the floating tooltip panel next to it.
private struct ButtonFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - ToolbarView

/// Minimalist vertical floating toolbar for recording controls.
/// The settings popover embeds the full configuration UI (ContentView).
struct ToolbarView: View {
    @EnvironmentObject var controller: RecordingController
    @EnvironmentObject var tooltipController: TooltipController

    @State private var showSettings = false
    @State private var showBackgrounds = false
    @State private var hovered: String?
    @State private var buttonFrames: [String: CGRect] = [:]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            pill
            if showStatus {
                statusCard
            }
        }
        .fixedSize()
        .preferredColorScheme(.dark)
        .task { await controller.refreshDevices() }
        // Collect button frames reported from within the pill
        .onPreferenceChange(ButtonFrameKey.self) { buttonFrames = $0 }
        // Drive the floating tooltip panel on hover changes
        .onChange(of: hovered) { _, id in
            if let id, let frame = buttonFrames[id], let text = tipText(for: id) {
                tooltipController.show(text: text, buttonGlobalFrame: frame)
            } else {
                tooltipController.hide()
            }
        }
    }

    // MARK: - Tooltip label map

    private func tipText(for id: String) -> String? {
        switch id {
        case "record":   return "Record"
        case "discard":  return "Discard"
        case "window":   return "Window"
        case "camera":   return controller.enableCamera ? "Camera on" : "Camera off"
        case "bg":       return "Background"
        case "settings": return "Settings"
        case "folder":   return "Reveal"
        default:         return nil
        }
    }

    // MARK: - Pill

    private var pill: some View {
        VStack(spacing: 6) {
            if controller.isCompressing {
                compressingIndicator
            } else {
                // Record / Stop
                recordButton

                if controller.isRecording {
                    Text(controller.elapsedString)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    discardButton
                }
            }

            divider

            // Pick a window to record (native click-to-select)
            iconButton("macwindow", id: "window") {
                Task { await controller.chooseWindow() }
            }

            // Toggle webcam on/off
            cameraToggleButton

            // Background swatch — shows current, opens picker
            backgroundSwatchButton

            // Settings
            iconButton("gearshape", id: "settings") {
                showSettings.toggle()
            }
            .popover(isPresented: $showSettings, arrowEdge: .trailing) {
                ContentView()
                    .environmentObject(controller)
                    .frame(width: 380)
            }

            // Reveal last recording
            if controller.lastOutputURL != nil {
                iconButton("folder", id: "folder") {
                    if let url = controller.lastOutputURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Show the status card only for actionable messages (not idle / recording).
    private var showStatus: Bool {
        !controller.isRecording &&
        controller.status != "Ready." &&
        !controller.status.isEmpty
    }

    private var statusCard: some View {
        Text(controller.status)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(3)
            .frame(maxWidth: 180, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Subviews

    private var recordButton: some View {
        Button {
            Task {
                if controller.isRecording { await controller.stop() }
                else if !controller.isCompressing { await controller.start() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(controller.isRecording ? Color.red.opacity(0.2) : Color.clear)
                    .frame(width: 42, height: 42)

                if controller.isRecording {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.red)
                        .frame(width: 16, height: 16)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 20, height: 20)
                }
            }
            .frame(width: 42, height: 42)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? "record" : nil }
        .scaleEffect(hovered == "record" ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .background(frameTracker(id: "record"))
    }

    private var cameraToggleButton: some View {
        Button {
            controller.enableCamera.toggle()
        } label: {
            Image(systemName: controller.enableCamera ? "video.fill" : "video.slash.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(controller.enableCamera
                                 ? .white.opacity(hovered == "camera" ? 1.0 : 0.85)
                                 : .white.opacity(hovered == "camera" ? 0.7 : 0.4))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isRecording)
        .onHover { inside in hovered = inside ? "camera" : nil }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .background(frameTracker(id: "camera"))
    }

    /// Discard the in-progress recording without saving (Loom-style trash).
    private var discardButton: some View {
        Button {
            Task { await controller.cancel() }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(hovered == "discard" ? 1.0 : 0.6))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? "discard" : nil }
        .scaleEffect(hovered == "discard" ? 1.12 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovered)
    }

    /// Clear "processing" state shown in place of the record button while the
    /// recording is being compressed — a progress ring with the % inside plus
    /// a "Saving" caption, so it's obvious the file isn't ready yet.
    private var compressingIndicator: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, controller.compressionProgress))
                    .stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: controller.compressionProgress)
                Text("\(Int(controller.compressionProgress * 100))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
            }
            .frame(width: 40, height: 40)

            Text("Saving")
                .font(.system(size: 8, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.orange.opacity(0.9))
        }
        .frame(width: 42)
        .help("Compressing recording…")
    }

    private var backgroundSwatchButton: some View {
        Button {
            showBackgrounds.toggle()
        } label: {
            controller.background.swatch
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(hovered == "bg" ? 0.6 : 0.3), lineWidth: 1)
                )
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? "bg" : nil }
        .scaleEffect(hovered == "bg" ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .popover(isPresented: $showBackgrounds, arrowEdge: .trailing) {
            backgroundPopover
        }
        .background(frameTracker(id: "bg"))
    }

    private var backgroundPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background").font(.headline)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
            var options: [BackgroundOption] {
                var list = BackgroundOption.presets
                if controller.background.id == "custom" { list.append(controller.background) }
                return list
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(options) { option in
                    let selected = controller.background.id == option.id
                    Button {
                        controller.background = option
                    } label: {
                        option.swatch
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        selected ? Color.accentColor : Color.white.opacity(0.2),
                                        lineWidth: selected ? 2.5 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.isRecording)
                }
            }

            HStack {
                Text("Padding")
                Picker("", selection: $controller.backgroundPadding) {
                    ForEach(BackgroundPadding.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 120)
                .disabled(controller.isRecording || controller.background.isNone)
                Spacer()
                Button("Image…") { controller.chooseBackgroundImage() }
                    .disabled(controller.isRecording)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func iconButton(_ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(hovered == id ? 1.0 : 0.65))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? id : nil }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .background(frameTracker(id: id))
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, 4)
    }

    /// Returns a transparent background view that reports this button's frame
    /// (in SwiftUI .global / window-relative coordinates) via ButtonFrameKey.
    private func frameTracker(id: String) -> some View {
        GeometryReader { geo in
            Color.clear
                .preference(key: ButtonFrameKey.self,
                            value: [id: geo.frame(in: .global)])
        }
    }
}
