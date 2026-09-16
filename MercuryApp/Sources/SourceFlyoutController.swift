import AppKit
import SwiftUI

// MARK: - Flyout content

/// The source picker that slides out beside the toolbar: Full Screen (per
/// display), Window, and any connected iPhones. Hover to open, click a row to
/// choose. Lives in its own floating panel so it is never clipped by the pill.
struct SourceFlyoutView: View {
    @EnvironmentObject var controller: RecordingController
    let onHover: (Bool) -> Void
    let dismiss: () -> Void

    @State private var hoveredRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Record")

            if controller.displays.count > 1 {
                ForEach(controller.displays, id: \.displayID) { d in
                    row(id: "display-\(d.displayID)",
                        title: "Display \(d.displayID)",
                        subtitle: "\(d.width)×\(d.height)",
                        symbol: "display",
                        active: controller.captureSource == .display && controller.selectedDisplayID == d.displayID) {
                        controller.selectDisplaySource(d.displayID)
                    }
                }
            } else {
                row(id: "display", title: "Full Screen", symbol: "display",
                    active: controller.captureSource == .display) {
                    controller.selectDisplaySource()
                }
            }

            row(id: "window",
                title: controller.pickedWindowName ?? "Window…",
                subtitle: controller.pickedWindowName == nil ? nil : "Click to change",
                symbol: "macwindow",
                active: controller.captureSource == .window) {
                Task { await controller.chooseWindow() }
            }

            Divider()
                .padding(.vertical, 4)
                .padding(.horizontal, 6)

            if controller.phones.isEmpty {
                row(id: "no-phone", title: "No iPhone connected",
                    subtitle: "Plug in, unlock, tap Trust",
                    symbol: "iphone.slash", active: false, enabled: false) {}
            } else {
                ForEach(controller.phones, id: \.uniqueID) { phone in
                    row(id: "phone-\(phone.uniqueID)", title: phone.localizedName, symbol: "iphone",
                        active: controller.captureSource == .phone && controller.selectedPhoneID == phone.uniqueID) {
                        controller.selectPhoneSource(phone.uniqueID)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 230)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover(perform: onHover)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 4)
    }

    private func row(id: String, title: String, subtitle: String? = nil, symbol: String,
                     active: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        let hovering = hoveredRow == id && enabled
        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20)
                .foregroundStyle(active ? Color.accentColor : .primary.opacity(enabled ? 0.8 : 0.35))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(enabled ? 0.9 : 0.4))
                    .lineLimit(1).truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if active {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { inside in hoveredRow = inside ? id : (hoveredRow == id ? nil : hoveredRow) }
        .onTapGesture {
            guard enabled else { return }
            action()
            dismiss()
        }
        .animation(.easeOut(duration: 0.12), value: hoveredRow)
    }
}

// MARK: - Controller

/// Owns the floating panel for `SourceFlyoutView`, opens it on hover with a
/// slide-and-fade from the toolbar, and closes it when the mouse leaves both
/// the toolbar button and the flyout.
@MainActor
final class SourceFlyoutController: ObservableObject {
    /// The toolbar panel we slide out from (set by AppDelegate).
    weak var hostPanel: NSPanel?
    /// The recording controller the flyout reads and writes (set by AppDelegate).
    weak var recording: RecordingController?

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var insideButton = false
    private var insideFlyout = false
    @Published private(set) var isShown = false

    private let slideDistance: CGFloat = 14
    private let gap: CGFloat = 10

    // MARK: Hover / click API (called from the toolbar)

    func buttonHover(_ inside: Bool) {
        insideButton = inside
        if inside {
            hideTask?.cancel()
            guard !isShown else { return }
            showTask?.cancel()
            showTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self?.show()
            }
        } else {
            showTask?.cancel()
            scheduleHide()
        }
    }

    func toggle() {
        if isShown { hide() } else { show() }
    }

    private func flyoutHover(_ inside: Bool) {
        insideFlyout = inside
        if inside { hideTask?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard let self, !Task.isCancelled, !self.insideButton, !self.insideFlyout else { return }
            self.hide()
        }
    }

    // MARK: Show / hide

    func show() {
        guard let host = hostPanel, let recording else { return }
        ensurePanel(with: recording)
        guard let panel, let hosting else { return }

        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 40 || size.height < 40 { size = CGSize(width: 230, height: 160) }

        let hf = host.frame
        let screen = host.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        // Slide out to the LEFT of the toolbar (it's docked at the right edge);
        // flip to the right if there's no room.
        var x = hf.minX - gap - size.width
        var fromDX = slideDistance
        if x < screen.minX + 4 {
            x = hf.maxX + gap
            fromDX = -slideDistance
        }
        // Centre on the mouse (it's over the source button when this opens).
        var y = NSEvent.mouseLocation.y - size.height / 2
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)

        let final = NSRect(x: x, y: y, width: size.width, height: size.height)

        if isShown {
            panel.setFrame(final, display: true)
            return
        }
        isShown = true
        hideTask?.cancel()

        panel.alphaValue = 0
        panel.setFrame(final.offsetBy(dx: fromDX, dy: 0), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown, let panel else { return }
        isShown = false
        let dx: CGFloat = (hostPanel.map { panel.frame.minX < $0.frame.minX } ?? true) ? slideDistance : -slideDistance
        let target = panel.frame.offsetBy(dx: dx, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard self?.isShown == false else { return }
                panel.orderOut(nil)
            }
        })
    }

    // MARK: Panel

    private func ensurePanel(with recording: RecordingController) {
        guard panel == nil else { return }
        let view = SourceFlyoutView(
            onHover: { [weak self] inside in self?.flyoutHover(inside) },
            dismiss: { [weak self] in self?.hide() }
        )
        .environmentObject(recording)

        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.required, for: .vertical)
        self.hosting = hosting

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        self.panel = panel
    }
}
