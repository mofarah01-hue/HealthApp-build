import SwiftUI
import MGContext
import MGDesign

// "Pair with QR" (UX-SPEC §14 Strap & sync › PC Lab; ARCHITECTURE §5.2): scan the code `python -m mglab pair` shows,
// or paste its link. Camera scanning uses AVFoundation (StrapQRScannerView); with no camera, a refused permission or a
// failed session, the paste field is the way in. The link is parsed with MGSync's `PairingPayload(url:)` by
// `PairingController`. Owner: WP-13.
//
// Presenting: the app answers `UIIntent.pairPC` with `.sheet { PairingSheet(controller:close:) }`; WP-23 builds the
// controller with a closure that calls `SyncEngine.pair(_:deviceName:)`, and forwards `mgapp://pair…` URLs opened
// from outside (`.onOpenURL`) to `controller.handle(url:)`.

struct PairingSheet: View {
    @ObservedObject var controller: PairingController
    let close: () -> Void

    @Environment(\.mgTheme) private var theme
    @Environment(\.mgColors) private var colors
    @State private var camera: StrapCameraAccess = .checking
    @State private var cameraMessage: String?
    @State private var link: String = ""

    init(controller: PairingController, close: @escaping () -> Void) {
        self.controller = controller
        self.close = close
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                scannerBlock
                    .padding(.top, 16)
                statusBlock
                    .padding(.top, 14)
                pasteBlock
                helpBlock
            }
            .padding(.horizontal, MGSpace.gutter)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.colors(for: theme).sheet.color.ignoresSafeArea())
        .task { camera = await StrapCameraAccess.resolve() }
        .onChange(of: controller.phase) { _, newPhase in
            // The link holds a one-time token: clear it as soon as it has been used.
            if case .paired = newPhase { link = "" }
        }
        .mgTheme(theme)
        .preferredColorScheme(Theme.colors(for: theme).isDark ? .dark : .light)
        .presentationBackground(Theme.colors(for: theme).sheet.color)
        .presentationCornerRadius(MGRadius.sheet)
        .presentationDragIndicator(.visible)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("PC Lab")
                    .mgFont(.kicker)
                    .foregroundStyle(colors.topText.color)
                Spacer(minLength: 8)
                MGButton(isPaired ? "Done" : "Cancel", weight: isPaired ? .filled : .tonal, action: close)
            }
            Text("Pair PC Lab")
                .mgFont(.sheetTitle)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text("On the PC run python -m mglab pair, then scan the code it shows. Tailscale must be on for both. "
                 + "A code works once and lasts 10 minutes.")
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isPaired: Bool {
        if case .paired = controller.phase { return true }
        return false
    }

    private var isBusy: Bool {
        switch controller.phase {
        case .pairing, .paired: return true
        case .ready, .failed: return false
        }
    }

    // MARK: camera

    @ViewBuilder private var scannerBlock: some View {
        if isBusy {
            EmptyView()
        } else {
            switch camera {
            case .checking:
                scannerPlaceholder {
                    ProgressView().tint(colors.ink.color)
                    Text("Checking the camera…").mgFont(.detail).foregroundStyle(colors.ink2.color)
                }
            case .ready:
                if let message = cameraMessage {
                    scannerPlaceholder {
                        Text(message).mgFont(.body).foregroundStyle(colors.ink2.color)
                        Text("Paste the link below instead.").mgFont(.detail).foregroundStyle(colors.ink2.color)
                    }
                } else {
                    viewfinder
                }
            case .denied:
                scannerPlaceholder {
                    Text("Camera access is off for this app.").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                    Text("Allow it in iOS Settings › MG › Camera, or paste the link below instead.")
                        .mgFont(.body).foregroundStyle(colors.ink2.color)
                    MGButton("Open Settings", weight: .tonal) { PairingSheet.openSettings() }
                }
            case .unavailable:
                scannerPlaceholder {
                    Text("No camera available here.").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                    Text("A simulator has none. Paste the link below instead.")
                        .mgFont(.detail).foregroundStyle(colors.ink2.color)
                }
            }
        }
    }

    private var viewfinder: some View {
        StrapQRScannerView(
            onCode: { controller.handleScanned($0) },
            onFailure: { cameraMessage = $0 })
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: MGRadius.card, style: .continuous))
            .overlay { StrapViewfinderCorners(color: colors.buttonText.color).padding(28) }
            .overlay(RoundedRectangle(cornerRadius: MGRadius.card, style: .continuous)
                .strokeBorder(colors.rule.color, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera view for the pairing code")
            .accessibilityHint("Point the camera at the code shown on your PC")
    }

    private func scannerPlaceholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(MGSpace.cardInset)
        .mgSurface(.card, radius: MGRadius.card)
    }

    private static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: status

    @ViewBuilder private var statusBlock: some View {
        switch controller.phase {
        case .ready:
            EmptyView()
        case .pairing(let pc):
            HStack(spacing: 10) {
                ProgressView().tint(colors.ink.color)
                Text("Pairing with \(pc)…").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
            }
            .accessibilityElement(children: .combine)
        case .paired(let pc):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(colors.text(.focus).color)
                        .accessibilityHidden(true)
                    Text("Paired with \(pc).").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                }
                Text("Your data now goes to this PC over Tailscale, and nowhere else.")
                    .mgFont(.body).foregroundStyle(colors.ink2.color)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(colors.text(.body).color)
                        .accessibilityHidden(true)
                    Text(message)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("A code works once and expires after 10 minutes. If this one was used or is old, run "
                     + "python -m mglab pair for a new one.")
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                MGButton("Try again", weight: .tonal) { controller.reset() }
            }
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: paste

    @ViewBuilder private var pasteBlock: some View {
        if !isPaired {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Or paste the link", note: "starts mgapp://pair")
                TextField("mgapp://pair?v=1&base=…&token=…", text: $link, axis: .vertical)
                    .lineLimit(2...5)
                    .mgFont(.receipt)
                    .foregroundStyle(colors.ink.color)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { controller.handleLink(link) }
                    // r8h T6: a vertical-axis field turns Return into a line break, so "Go" did nothing. A pasted or typed
                    // line break is taken as Go instead.
                    .onChange(of: link) { _, new in
                        guard new.contains("\n") else { return }
                        link = new.replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespaces)
                        if !isBusy { controller.handleLink(link) }
                    }
                    .padding(12)
                    .mgSurface(.card, radius: MGRadius.chip + 4)
                    .disabled(isBusy)
                    .accessibilityLabel("Pairing link")
                HStack(spacing: 10) {
                    MGButton("Paste", weight: .tonal) {
                        if let text = UIPasteboard.general.string { link = text }
                    }
                    MGButton("Pair", style: .filled) { controller.handleLink(link) }
                        .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                        .opacity(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy ? 0.5 : 1)
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: help

    private var helpBlock: some View {
        Text("The code carries your PC's address and a one-time token. It is checked on the PC; nothing is sent anywhere else.")
            .mgFont(.body)
            .foregroundStyle(colors.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
    }
}

/// Four corner brackets over the camera view.
private struct StrapViewfinderCorners: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                let arm: CGFloat = 28
                path.move(to: CGPoint(x: 0, y: arm)); path.addLine(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: arm, y: 0))
                path.move(to: CGPoint(x: w - arm, y: 0)); path.addLine(to: CGPoint(x: w, y: 0)); path.addLine(to: CGPoint(x: w, y: arm))
                path.move(to: CGPoint(x: w, y: h - arm)); path.addLine(to: CGPoint(x: w, y: h)); path.addLine(to: CGPoint(x: w - arm, y: h))
                path.move(to: CGPoint(x: arm, y: h)); path.addLine(to: CGPoint(x: 0, y: h)); path.addLine(to: CGPoint(x: 0, y: h - arm))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
