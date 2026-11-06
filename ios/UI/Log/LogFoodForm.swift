
import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Food, opened in place (UX §7, APP-080): type it, ingredient tags (including the EoE set), portion S / M / L, optional
/// calories. Calories typed here are saved as `estimate_method: manual`. Photo calories, when added, will be labelled
/// "AI estimate, unverified" (APP-085).
/// Tracker #42 (2026-10-11): a quality rating 1–5 (contract v0.5), protein / carbs / fat in g, and a meal photo kept on
/// this phone only (MealPhotos: small JPEG by event id, never uploaded, not named in the event). This comment used to
/// say "Photo and barcode are shown disabled with their reason: a photo needs the attachment store and the
/// location-stripping step (APP-116)" — the photo no longer leaves the phone, so neither is needed; barcode stays later.
struct LogFoodForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @State private var text = ""
    @State private var tags: Set<String> = []
    @State private var portion: FoodFields.Portion?
    @State private var kcalText = ""
    @State private var proteinText = ""
    @State private var carbText = ""
    @State private var fatText = ""
    @State private var quality: Int?
    @State private var picking = false
    @State private var photo: UIImage?
    @State private var when = LogHappenedAt()

    private var kcal: Double? { LogText.parse(kcalText) }
    private var hasContent: Bool { LogText.clean(text) != nil || !tags.isEmpty || photo != nil }
    private var macroTexts: [String] { [kcalText, proteinText, carbText, fatText] }
    private var badNumber: Bool { macroTexts.contains { !$0.isEmpty && (LogText.parse($0) ?? -1) < 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                LogFormLabel("What did you eat")
                LogTextField("Type it — a few words", text: $text)
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    Button { picking = true } label: {
                        Text(photo == nil ? "Add a photo" : "Change photo")
                            .mgFont(.detail)
                            .padding(.horizontal, 12)
                            .frame(minHeight: MGSpace.tapTarget)
                    }
                    .buttonStyle(.plain)
                }
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous))
                        .accessibilityLabel("Meal photo")
                }
                LogHint("The photo stays on this phone, small (about 0.2 MB); it is never uploaded.")
            }
            .sheet(isPresented: $picking) {
                MealPhotoPicker { image in
                    if let image { photo = image }
                    picking = false
                }
            }

            LogFormLabel("Quality")
            LogChoiceChips(options: (1...5).map { (id: $0, label: LogFoodForm.qualityWords[$0 - 1]) },
                           selection: $quality)

            LogFormLabel("Ingredients")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(LogVocabulary.foodTags) { tag in
                    Chip(tag.label, selected: tags.contains(tag.id)) {
                        if tags.contains(tag.id) { _ = tags.remove(tag.id) } else { _ = tags.insert(tag.id) }
                    }
                }
            }

            LogFormLabel("Portion")
            LogChoiceChips(options: [(id: FoodFields.Portion.s, label: "S"), (id: FoodFields.Portion.m, label: "M"),
                                     (id: FoodFields.Portion.l, label: "L")],
                           selection: $portion)

            LogFormLabel("Calories and macros (optional)")
            HStack(spacing: 8) {
                LogTextField("If you know it", text: $kcalText, decimal: true)
                LogUnitLabel("kcal")
            }
            HStack(spacing: 8) {
                LogTextField("Protein", text: $proteinText, decimal: true)
                LogTextField("Carbs", text: $carbText, decimal: true)
                LogTextField("Fat", text: $fatText, decimal: true)
                LogUnitLabel("g")
            }

            LogHappenedAtControl(choice: $when)
            LogSaveBar(title: "Log food", enabled: canSave, reason: reason, action: save)
        }
        .keepsDraft($text, row: ctx.row.id, field: "text")
        .keepsDraft($kcalText, row: ctx.row.id, field: "kcal")
        .keepsDraft($proteinText, row: ctx.row.id, field: "protein")
        .keepsDraft($carbText, row: ctx.row.id, field: "carb")
        .keepsDraft($fatText, row: ctx.row.id, field: "fat")
    }

    /// 1 poor … 5 very good (Mo's own scale, contract v0.5 `quality`).
    static let qualityWords = ["1 poor", "2", "3 ok", "4", "5 very good"]

    private var canSave: Bool { ctx.canLog && hasContent && !badNumber }

    private var reason: String? {
        if !ctx.canLog { return LogIntents.sampleReason }
        if !hasContent { return "Type what you ate, pick an ingredient or add a photo." }
        if badNumber { return "Calories and macros must be numbers of 0 or more." }
        return nil
    }

    private func save() {
        guard canSave else { return }
        let now = Date()
        let at = when.resolved(now: now, calendar: calendar)
        // Tags keep the list's order so two entries with the same tags are written the same way.
        let ordered = LogVocabulary.foodTags.map { $0.id }.filter { tags.contains($0) }
        let event = LogEvents.food(text: LogText.clean(text), tags: ordered, portion: portion, kcal: kcal,
                                   proteinG: LogText.parse(proteinText), carbG: LogText.parse(carbText),
                                   fatG: LogText.parse(fatText), quality: quality, at: at, loggedAt: now)
        var message = "Food logged \(LogText.time(at, calendar))"
        if let photo {
            do {
                let bytes = try MealPhotos.save(photo, eventId: event.id)
                message += " · photo on this phone (\(bytes / 1024) KB)"
            } catch {
                message += " · photo not saved: \(error.localizedDescription)"
            }
        }
        ctx.commit([event], message: message)
    }
}
