import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// A themed multi-line text box.
struct LogTextArea: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        TextField(text: $text, prompt: Text(title).foregroundStyle(colors.mute.color), axis: .vertical) {
            Text(title)
        }
        .mgFont(.body)
        .foregroundStyle(colors.ink.color)
        .lineLimit(2...6)
        .padding(12)
        .frame(minHeight: 64, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous).fill(colors.chip.color))
        .accessibilityLabel(title)
    }
}

/// More › (UX §7): Health record (APP-087), scan, BP cuff reading typed by hand. The reaction test is run from
/// Sleepy & check-in.
struct LogMoreForm: View {
    let ctx: LogFormContext

    enum Kind: String {
        case record, scan, bp, activity
    }

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @State private var kind: Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogChoiceChips(options: [(id: Kind.record, label: "Health record"), (id: Kind.scan, label: "Scan"),
                                     (id: Kind.bp, label: "BP cuff reading"),
                                     (id: Kind.activity, label: "What are you doing?")],
                           selection: $kind)
            switch kind {
            case .record:
                LogRecordForm(ctx: ctx)
            case .scan:
                LogScanForm(ctx: ctx)
            case .bp:
                LogBPCuffForm(ctx: ctx)
            case .activity:
                LogActivityForm(ctx: ctx)
            case nil:
                LogHint("Injury or doctor note · InBody, DEXA, X-ray, MRI, ultrasound · a cuff reading you typed. The reaction test is in Sleepy & check-in.")
            }
        }
    }
}

// MARK: - Shared date control for records and scans

private struct LogDateField: View {
    let title: String
    @Binding var date: Date

    init(_ title: String, date: Binding<Date>) {
        self.title = title
        self._date = date
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        DatePicker(title, selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
            .mgFont(.detail)
            .foregroundStyle(colors.ink.color)
            .environment(\.locale, AlarmTimeLocale.picker)
            .frame(minHeight: MGSpace.tapTarget)
    }
}

private let logSideOptions: [(id: String, label: String)] = [
    (id: "left", label: "left"), (id: "right", label: "right"), (id: "both", label: "both"), (id: "n/a", label: "n/a"),
]

// MARK: - Health record

struct LogRecordForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.calendar) private var calendar
    @State private var kind: RecordFields.Kind?
    @State private var bodyPart = ""
    @State private var side: String?
    @State private var clinician = ""
    @State private var status: RecordFields.Status?
    @State private var text = ""
    @State private var date = Date()
    @State private var hasEnded = false
    @State private var ended = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LogFormLabel("Health record")
            LogChoiceChips(options: [(id: RecordFields.Kind.injury, label: "injury"),
                                     (id: RecordFields.Kind.doctorNote, label: "doctor note"),
                                     (id: RecordFields.Kind.diagnosis, label: "diagnosis"),
                                     (id: RecordFields.Kind.labReport, label: "lab report")],
                           selection: $kind)
            LogTextField("Body part (left shoulder…)", text: $bodyPart)
            LogChoiceChips(options: logSideOptions, selection: $side)
            LogTextField("Clinician (optional)", text: $clinician)
            LogChoiceChips(options: [(id: RecordFields.Status.active, label: "active"),
                                     (id: RecordFields.Status.resolved, label: "resolved")],
                           selection: $status)
            LogTextArea("What happened, what was said", text: $text)
            LogDateField(kind == .injury ? "Started" : "Date", date: $date)
            // Tracker #42 (2026-10-11): an injury's end date (contract recordEvent.end); listed in Settings › Profile.
            Toggle(kind == .injury ? "It has ended" : "It ended on a date", isOn: $hasEnded)
                .mgFont(.detail)
            if hasEnded {
                LogDateField("Ended", date: $ended)
            }
            LogSaveBar(title: "Save record", enabled: ctx.canLog && kind != nil && !endsBeforeStart,
                       reason: !ctx.canLog ? LogIntents.sampleReason
                           : (endsBeforeStart ? "The end is before the start." : "Pick the kind of record."),
                       action: save)
        }
        .keepsDraft($bodyPart, row: ctx.row.id, field: "recordBody")
        .keepsDraft($clinician, row: ctx.row.id, field: "clinician")
        .keepsDraft($text, row: ctx.row.id, field: "recordText")
    }

    private var endsBeforeStart: Bool { hasEnded && ended < date }

    private func save() {
        guard ctx.canLog, let kind, !endsBeforeStart else { return }
        let now = Date()
        let sideValue: RecordFields.Side? = side.flatMap { RecordFields.Side(rawValue: $0) }
        let event = LogEvents.record(kind: kind, bodyPart: LogText.clean(bodyPart), side: sideValue,
                                     clinician: LogText.clean(clinician),
                                     status: status ?? (hasEnded && kind == .injury ? .resolved : nil),
                                     text: LogText.clean(text), end: hasEnded ? min(ended, now) : nil,
                                     at: min(date, now), loggedAt: now)
        ctx.commit([event], message: "Record saved \(LogText.time(min(date, now), calendar))")
    }
}

// MARK: - Scan

struct LogScanForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.calendar) private var calendar
    @State private var kind: ScanFields.ScanKind?
    @State private var provider = ""
    @State private var bodyPart = ""
    @State private var side: String?
    @State private var note = ""
    @State private var date = Date()
    /// Tracker #42: the typed body-composition numbers by key (BodyComposition.fields), as typed.
    @State private var numbers: [String: String] = [:]

    private var isComposition: Bool { kind.map { BodyComposition.kinds.contains($0) } ?? false }
    private var composition: BodyComposition {
        BodyComposition(numbers: numbers.compactMapValues { LogText.parse($0) })
    }
    private var badNumber: Bool { numbers.values.contains { !$0.isEmpty && (LogText.parse($0) ?? -1) < 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LogFormLabel("Scan")
            LogChoiceChips(options: [(id: ScanFields.ScanKind.inbody, label: "InBody"),
                                     (id: ScanFields.ScanKind.dexa, label: "DEXA"),
                                     (id: ScanFields.ScanKind.xray, label: "X-ray"),
                                     (id: ScanFields.ScanKind.mri, label: "MRI"),
                                     (id: ScanFields.ScanKind.ultrasound, label: "ultrasound"),
                                     (id: ScanFields.ScanKind.other, label: "other")],
                           selection: $kind)
            LogTextField("Where it was done (optional)", text: $provider)
            LogTextField("Body part (optional)", text: $bodyPart)
            LogChoiceChips(options: logSideOptions, selection: $side)
            if isComposition {
                LogFormLabel(kind == .other ? "Measurements (tape, scale…)" : "Numbers from the printout")
                ForEach(BodyComposition.fields, id: \.key) { f in
                    HStack(spacing: 8) {
                        LogTextField(f.label, text: Binding(get: { numbers[f.key] ?? "" },
                                                            set: { numbers[f.key] = $0 }), decimal: true)
                        LogUnitLabel(f.unit)
                    }
                }
                LogHint("Type what the device printed; blank fields are left out. Waist feeds the VO₂max estimate (ALG-036). Neck + waist (+ hip for women) give a tape body-fat estimate in Preferences › Records.")
            }
            LogTextArea("Result in your words (optional)", text: $note)
            LogDateField("Date", date: $date)
            LogSaveBar(title: "Save scan", enabled: ctx.canLog && kind != nil && !badNumber,
                       reason: !ctx.canLog ? LogIntents.sampleReason
                           : (badNumber ? "Numbers must be 0 or more." : "Pick the kind of scan."), action: save)
        }
        .keepsDraft($provider, row: ctx.row.id, field: "provider")
        .keepsDraft($bodyPart, row: ctx.row.id, field: "scanBody")
        .keepsDraft($note, row: ctx.row.id, field: "scanNote")
    }

    private func save() {
        guard ctx.canLog, let kind else { return }
        let now = Date()
        let sideValue: ScanFields.Side? = side.flatMap { ScanFields.Side(rawValue: $0) }
        let event = LogEvents.scan(kind: kind, provider: LogText.clean(provider), bodyPart: LogText.clean(bodyPart),
                                   side: sideValue, note: LogText.clean(note),
                                   composition: isComposition ? composition : BodyComposition(),
                                   at: min(date, now), loggedAt: now)
        ctx.commit([event], message: "Scan saved \(LogText.time(min(date, now), calendar))")
    }
}

// MARK: - BP cuff

struct LogBPCuffForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.calendar) private var calendar
    @State private var systolic = ""
    @State private var diastolic = ""
    @State private var pulse = ""
    @State private var posture: BPCuffFields.Posture?
    @State private var arm: BPCuffFields.Arm?
    @State private var when = LogHappenedAt()

    private var problem: String? {
        LogEvents.bpProblem(systolic: LogText.parse(systolic), diastolic: LogText.parse(diastolic),
                            pulse: pulse.isEmpty ? nil : (LogText.parse(pulse) ?? -1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LogFormLabel("BP cuff reading")
            HStack(spacing: 8) {
                LogTextField("Top", text: $systolic, decimal: true)
                LogTextField("Bottom", text: $diastolic, decimal: true)
                LogUnitLabel("mmHg")
            }
            HStack(spacing: 8) {
                LogTextField("Pulse (optional)", text: $pulse, decimal: true)
                LogUnitLabel("bpm")
            }
            LogChoiceChips(options: [(id: BPCuffFields.Posture.sitting, label: "sitting"),
                                     (id: BPCuffFields.Posture.standing, label: "standing"),
                                     (id: BPCuffFields.Posture.lying, label: "lying")],
                           selection: $posture)
            LogChoiceChips(options: [(id: BPCuffFields.Arm.left, label: "left arm"),
                                     (id: BPCuffFields.Arm.right, label: "right arm")],
                           selection: $arm)
            LogHappenedAtControl(choice: $when, title: "Measured · minutes ago")
            LogHint("A cuff reading typed by hand is saved as measured. It is never turned into advice.")
            LogSaveBar(title: "Save reading", enabled: ctx.canLog && problem == nil,
                       reason: ctx.canLog ? problem : LogIntents.sampleReason, action: save)
        }
        .keepsDraft($systolic, row: ctx.row.id, field: "sys")
        .keepsDraft($diastolic, row: ctx.row.id, field: "dia")
        .keepsDraft($pulse, row: ctx.row.id, field: "pulse")
    }

    private func save() {
        guard ctx.canLog, problem == nil, let sys = LogText.parse(systolic), let dia = LogText.parse(diastolic) else { return }
        let now = Date()
        let at = when.resolved(now: now, calendar: calendar)
        let event = LogEvents.bpCuff(systolic: sys, diastolic: dia, pulse: LogText.parse(pulse), posture: posture,
                                     arm: arm, at: at, loggedAt: now)
        ctx.commit([event], message: "BP \(LogText.number(sys))/\(LogText.number(dia)) saved \(LogText.time(at, calendar))")
    }
}
