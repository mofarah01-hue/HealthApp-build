import SwiftUI
import MGBLE
import MGContext
import MGDesign
import MGDomain

// The confirm sheet for strap writes that are not covered by the standing clock consent (ARCHITECTURE D7, §4.4.5):
// since 2026-10-11 that is the one R22 write (SET_FF_VALUE enable_r22_packets = '1') and its restore. It shows
// old → new and hands back a `StrapWriteDecision`; MGBLE writes nothing until it sees `.confirmed`. Owner: WP-13.
//
//  • `UnlockConfirmPresenter` is the app's `StrapWriteConfirmer` (ARCHITECTURE §4.2: "UnlockConfirmPresenter in
//    WP-13's sheet"). MGBLE awaits `confirm(_:)`; the presenter publishes the plan; the sheet resolves it.
//  • `.strapUnlockConfirmSheet(presenter)` attaches the sheet to any view (WP-23 puts it on the root).
//  • `UnlockConfirmSheet` is the sheet itself; `StrapUnlockReportSheet` shows the `UnlockReport` that follows.
//
// Dismissing the sheet by any route other than the confirm button is a decline: nothing is written.
// The sheet appears from Strap & sync › "R22 research stream" (enable or restore).

// MARK: - Presenter (the StrapWriteConfirmer)

@MainActor
final class UnlockConfirmPresenter: ObservableObject, StrapWriteConfirmer {
    /// The plan waiting for Mo's decision; nil when none.
    @Published private(set) var plan: StrapWritePlan?

    private var continuation: CheckedContinuation<StrapWriteDecision, Never>?

    init() {}

    /// Called by MGBLE before any non-standing strap write. Suspends until `decide(_:)`.
    /// `nonisolated` so it matches the (nonisolated, async) protocol requirement exactly; the state change hops to
    /// the main actor inside.
    nonisolated func confirm(_ plan: StrapWritePlan) async -> StrapWriteDecision {
        await withCheckedContinuation { (continuation: CheckedContinuation<StrapWriteDecision, Never>) in
            Task { @MainActor in self.begin(plan, continuation) }
        }
    }

    /// A second plan arriving while one is open declines the first (a continuation is never left hanging).
    private func begin(_ plan: StrapWritePlan, _ continuation: CheckedContinuation<StrapWriteDecision, Never>) {
        resolve(.declined)
        self.continuation = continuation
        self.plan = plan
    }

    /// The sheet's two buttons, and any dismissal (= `.declined`).
    func decide(_ decision: StrapWriteDecision) {
        resolve(decision)
    }

    private func resolve(_ decision: StrapWriteDecision) {
        let pending = continuation
        continuation = nil
        plan = nil
        pending?.resume(returning: decision)
    }
}

extension View {
    /// Shows the confirm sheet whenever `presenter` holds a plan.
    func strapUnlockConfirmSheet(_ presenter: UnlockConfirmPresenter) -> some View {
        modifier(StrapUnlockConfirmSheetModifier(presenter: presenter))
    }
}

private struct StrapUnlockConfirmSheetModifier: ViewModifier {
    @ObservedObject var presenter: UnlockConfirmPresenter

    func body(content: Content) -> some View {
        content.sheet(item: planBinding) { plan in
            UnlockConfirmSheet(plan: plan) { decision in presenter.decide(decision) }
        }
    }

    /// Swipe-down sets the item to nil: that is a decline, and nothing is written.
    private var planBinding: Binding<StrapWritePlan?> {
        Binding(
            get: { presenter.plan },
            set: { newValue in
                if newValue == nil { presenter.decide(.declined) }
            })
    }
}

// MARK: - The sheet

struct UnlockConfirmSheet: View {
    let plan: StrapWritePlan
    /// The decision handed back to the caller: `.confirmed(at:)` with the time of the tap, or `.declined`.
    let decide: (StrapWriteDecision) -> Void
    private let now: () -> Date

    @Environment(\.mgTheme) private var theme
    @Environment(\.mgColors) private var colors

    init(plan: StrapWritePlan, decide: @escaping (StrapWriteDecision) -> Void,
         now: @escaping () -> Date = { Date() }) {
        self.plan = plan
        self.now = now
        self.decide = decide
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                changes
                risks
                footnote
            }
            .padding(.horizontal, MGSpace.gutter)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Theme.colors(for: theme).sheet.color.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { buttons }
        .mgTheme(theme)
        .preferredColorScheme(Theme.colors(for: theme).isDark ? .dark : .light)
        .presentationBackground(Theme.colors(for: theme).sheet.color)
        .presentationCornerRadius(MGRadius.sheet)
        .presentationDragIndicator(.visible)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Confirm strap write")
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text(plan.title)
                .mgFont(.sheetTitle)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(plan.reason)
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: old → new

    private var changes: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("What changes", note: "\(plan.items.count) \(plan.items.count == 1 ? "write" : "writes")")
            MGCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(plan.items.enumerated()), id: \.offset) { index, item in
                        StrapUnlockPlanRow(item: item)
                        if index < plan.items.count - 1 { StrapRule() }
                    }
                }
            }
        }
    }

    // MARK: risks

    @ViewBuilder private var risks: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Before you confirm")
            ForEach(Array(plan.risks.enumerated()), id: \.offset) { _, risk in
                bullet(risk)
            }
            bullet(restorableLine)
            let unread = plan.items.filter { $0.currentValue == nil }.count
            if unread > 0 {
                bullet("\(unread) \(unread == 1 ? "value" : "values") could not be read from the strap first, so "
                       + "\(unread == 1 ? "it" : "they") cannot be restored from the log.")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").mgFont(.body).foregroundStyle(colors.ink2.color).accessibilityHidden(true)
            Text(text)
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var restorableLine: String {
        switch plan.restorable {
        case .some(true): return "Restorable: each prior value is logged first and can be written back."
        case .some(false): return "Not fully restorable."
        case .none: return "Restorable: not known for this write."
        }
    }

    private var footnote: some View {
        Text("Each write is sent with response, read back from the strap, and logged (value before, payload, read-back) "
             + "in the Strap write log. The run stops at the first failure.")
            .mgFont(.body)
            .foregroundStyle(colors.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
    }

    // MARK: buttons

    private var buttons: some View {
        VStack(spacing: 8) {
            Rectangle().fill(colors.rule.color).frame(height: 1)
            // Wraps onto two lines at large text sizes instead of squeezing the labels.
            FlowLayout(spacing: 10, lineSpacing: 8) {
                MGButton("Cancel — write nothing", weight: .tonal) { decide(.declined) }
                MGButton(confirmTitle, style: .filled) { decide(.confirmed(at: now())) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MGSpace.gutter)
            .padding(.bottom, 8)
        }
        .background(colors.sheet.color)
    }

    private var confirmTitle: String {
        let n = plan.items.count
        return "Write \(n) \(n == 1 ? "value" : "values")"
    }
}

/// One planned write: the flag, the value now, the value to be written.
struct StrapUnlockPlanRow: View {
    let item: PlannedWrite
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .mgFont(.receipt)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 8) {
                valueChip(label: "now", text: current, emphasised: item.currentValue == nil)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colors.ink2.color)
                    .accessibilityHidden(true)
                valueChip(label: "will be", text: StrapUnlockPlanText.newValue(for: item), emphasised: false)
                if StrapUnlockPlanText.isUnchanged(item) {
                    Text("no change")
                        .mgFont(.label)
                        .foregroundStyle(colors.mute.color)
                }
            }
            Text("command \(item.command)")
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(item.name). Now \(current). Will be \(StrapUnlockPlanText.newValue(for: item)).")
    }

    private var current: String { item.currentValue ?? "couldn't be read" }

    private func valueChip(label: String, text: String, emphasised: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).mgFont(.label).foregroundStyle(colors.mute.color)
            Text(text)
                .mgFont(.receipt)
                .foregroundStyle(emphasised ? colors.text(.body).color : colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous).fill(colors.chip.color))
    }
}

/// Wording of a planned write. Pure, so a test can pin it without a view.
enum StrapUnlockPlanText {
    /// The value text a SET_FF_VALUE (120) plan will write, read from the plan's own payload so the sheet shows what
    /// will really be sent: payload = [01] + key 32 + value 32 (65 bytes; MGBLE `SanctionedCommand.setR22Packets`),
    /// the value is the text before the first NUL of payload[33..<65]. Any other shape shows the payload bytes
    /// themselves rather than a guess.
    static func newValue(for item: PlannedWrite) -> String {
        guard let text = valueText(item) else {
            return item.payloadHex.isEmpty ? "(empty payload)" : "payload " + shortened(item.payloadHex)
        }
        return "'\(text)'"
    }

    /// true when the value read from the strap ("2") equals the one to be written.
    static func isUnchanged(_ item: PlannedWrite) -> Bool {
        guard let current = item.currentValue, let text = valueText(item) else { return false }
        return current.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "'\""))) == text
    }

    private static func valueText(_ item: PlannedWrite) -> String? {
        guard item.command == 120, let bytes = hexBytes(fromHex: item.payloadHex), bytes.count == 65 else { return nil }
        let field = bytes[33..<65].prefix { $0 != 0 }
        guard !field.isEmpty, field.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: field, as: UTF8.self)
    }

    static func hexBytes(fromHex hex: String) -> [UInt8]? {
        let digits = hex.filter { !$0.isWhitespace }
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    private static func shortened(_ hex: String) -> String {
        hex.count <= 24 ? hex : String(hex.prefix(24)) + "…"
    }
}

// MARK: - What happened after the confirmation

/// The `UnlockReport` of a run or a restore: per flag the value before, the read-back, and the result; a failure
/// stops the run, and the sheet says so. Words and a glyph mark a failure, not colour alone.
struct StrapUnlockReportSheet: View {
    let report: UnlockReport
    let close: () -> Void

    @Environment(\.mgTheme) private var theme
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if report.items.isEmpty {
                    MGCard {
                        Text("No flag was written.")
                            .mgFont(.body)
                            .foregroundStyle(colors.ink2.color)
                    }
                    .padding(.top, 14)
                } else {
                    MGCard(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(report.items.enumerated()), id: \.offset) { index, item in
                                StrapUnlockReportRow(item: item)
                                if index < report.items.count - 1 { StrapRule() }
                            }
                        }
                    }
                    .padding(.top, 14)
                }
                Text("Every write is also in the Strap write log.")
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .padding(.top, 14)
            }
            .padding(.horizontal, MGSpace.gutter)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.colors(for: theme).sheet.color.ignoresSafeArea())
        .mgTheme(theme)
        .preferredColorScheme(Theme.colors(for: theme).isDark ? .dark : .light)
        .presentationBackground(Theme.colors(for: theme).sheet.color)
        .presentationCornerRadius(MGRadius.sheet)
        .presentationDragIndicator(.visible)
    }

    private var okCount: Int { report.items.filter { $0.result.lowercased() == "ok" }.count }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("Strap write result")
                    .mgFont(.kicker)
                    .foregroundStyle(colors.topText.color)
                Spacer(minLength: 8)
                MGButton("Done", style: .ghost, action: close)
            }
            Text("\(okCount) of \(report.items.count) written and read back OK")
                .mgFont(.sheetTitle)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if report.stoppedEarly {
                Text("The run stopped early; the flags after the last one listed were not written.")
                    .mgFont(.body)
                    .foregroundStyle(colors.text(.body).color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = report.note, !note.isEmpty {
                Text(note)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(MGFormat.time(report.startedAt, calendar: calendar))–\(MGFormat.time(report.endedAt, calendar: calendar))")
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
        }
    }
}

struct StrapUnlockReportRow: View {
    let item: UnlockItemResult
    @Environment(\.mgColors) private var colors

    private var ok: Bool { item.result.lowercased() == "ok" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .mgFont(.receipt)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            Text("before \(item.priorValue ?? "not read") → read-back \(item.readback ?? "not read")")
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !ok {
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.small)
                        .foregroundStyle(colors.text(.body).color)
                        .accessibilityHidden(true)
                }
                Text("result: \(item.result)")
                    .mgFont(.body)
                    .foregroundStyle(ok ? colors.ink2.color : colors.text(.body).color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
