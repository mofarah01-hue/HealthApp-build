import Combine
import Foundation
import MGContext
import MGDomain

// Places (tracker #41, Mo 2026-10-11: "home location and work and gym and soccer field pickup field"; purpose: tell a
// real walk from office work, stop "running around the house" becoming a workout, and ask him to confirm).
//   Settings › Places: add / rename / remove, "Use my current location" with a radius (PlacesLocation, one fix);
//   presence: region enter / exit + CLVisit → the visit log (MGContext PlaceLog), kept in kv `places.v1` on the phone;
//   the workout question (Today peek, Log confirm list) names the place and uses its prior (MGContext PlaceQuestion);
//   a confirmed workout is logged with the place's name and id only (eventBase.location), never coordinates;
//   a workout started by hand at a place gets its name (and the likely activity at Gym / the fields).
// Nothing is logged on its own: a candidate becomes a workout only when Mo answers.

/// What is kept (kv `places.v1`, phone only; not part of any upload).
struct PlacesStore: Codable, Equatable, Sendable {
    static let key = "places.v1"

    var places: [SavedPlace] = []
    var presenceOn = false
    var visits: [PlaceVisit] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        places = (try? c.decodeIfPresent([SavedPlace].self, forKey: .places)) ?? []
        presenceOn = (try? c.decodeIfPresent(Bool.self, forKey: .presenceOn)) ?? false
        visits = (try? c.decodeIfPresent([PlaceVisit].self, forKey: .visits)) ?? []
    }
}

/// The page's model: AppModel+Places fills it; UI/Places/PlacesView.swift observes `state`.
@MainActor
final class PlacesModel: ObservableObject {
    @Published var state: PlacesState?

    var store = PlacesStore()
    var loaded = false
    /// Presence events that came before the store was read (a background relaunch), applied after.
    var pending: [PlacesLocation.Event] = []
    var authorization: PlacesAuthorization = .notDetermined
    var note: String?
    let location = PlacesLocation()

    var snapshot: PlacesSnapshot { PlacesSnapshot(places: store.places, visits: store.visits) }
}

extension AppModel {
    private var pl: PlacesModel { places }

    // MARK: Lifecycle

    /// From `init`: the location callbacks first (a background relaunch delivers region events early), then the read.
    func wirePlaces() {
        pl.authorization = pl.location.authorization
        pl.location.onEvent = { [weak self] e in self?.placesEvent(e) }
        pl.location.onAuthorization = { [weak self] a in
            guard let self else { return }
            self.places.authorization = a
            self.placesPublish()
        }
        Task { [weak self] in await self?.placesLoad() }
    }

    func placesLoad() async {
        guard !pl.loaded else { return }
        do {
            pl.store = try await services.kv.load(PlacesStore.self, key: PlacesStore.key) ?? PlacesStore()
        } catch {
            if let raw = try? await services.store.value(forKey: PlacesStore.key) {
                try? await services.store.setValue(raw, forKey: PlacesStore.key + ".unreadable")
            }
            pl.note = "Your places couldn't be read; the old copy is kept. \(error)"
        }
        pl.loaded = true
        let waiting = pl.pending
        pl.pending = []
        for e in waiting { placesEvent(e) }
        if pl.store.presenceOn { pl.location.setPresence(true, places: pl.store.places) }
        placesPublish()
    }

    func placesSave() async {
        do { try await services.kv.save(pl.store, key: PlacesStore.key) } catch {
            showNotice("Your places weren't saved: \(error)")
        }
    }

    /// The app came to the front: ask iOS where Mo is now (region state; no GPS run).
    func placesBecameActive() {
        guard pl.loaded, pl.store.presenceOn, !isSample else { return }
        pl.location.checkStates()
    }

    // MARK: Page actions

    func placesAction(_ action: PlacesAction) async {
        await placesLoad()
        switch action {
        case .open:
            if paths[tab]?.last != .places { push(.places) }
            pl.authorization = pl.location.authorization
        case .add(let kind):
            pl.store.places.append(SavedPlace(name: kind.presetName, kind: kind))
            await placesSave()
        case let .rename(id, name):
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, let i = pl.store.places.firstIndex(where: { $0.id == id }) else { break }
            pl.store.places[i].name = String(clean.prefix(40))
            await placesSave()
        case let .setRadius(id, meters):
            guard let i = pl.store.places.firstIndex(where: { $0.id == id }) else { break }
            pl.store.places[i].radiusMeters = Double(min(500, max(50, meters)))
            await placesSave()
            placesWatch()
        case .remove(let id):
            pl.store.places.removeAll { $0.id == id }      // its old stays stay in the log, unnamed (ignored)
            await placesSave()
            placesWatch()
        case .useCurrentLocation(let id):
            pl.note = "Reading the location…"
            placesPublish()
            switch await pl.location.readPrecise() {
            case .success(let loc):
                if loc.horizontalAccuracy < 0 || loc.horizontalAccuracy > 100 {
                    pl.note = "That fix was ± \(Int(loc.horizontalAccuracy)) m — too vague for a place. Try again "
                        + "outside, or wait a moment."
                } else if let i = pl.store.places.firstIndex(where: { $0.id == id }) {
                    pl.store.places[i].latitude = loc.coordinate.latitude
                    pl.store.places[i].longitude = loc.coordinate.longitude
                    pl.store.places[i].setAt = clock.now
                    pl.note = "\(pl.store.places[i].name) set (± \(Int(loc.horizontalAccuracy.rounded())) m)."
                    await placesSave()
                    placesWatch()
                }
            case .failure(let f):
                pl.note = f.words
            }
            pl.authorization = pl.location.authorization
        case .setPresence(let on):
            guard !isSample else { return showNotice("Sample data is on — places aren't watched.") }
            pl.store.presenceOn = on
            await placesSave()
            pl.location.setPresence(on, places: pl.store.places)
            if on { pl.location.checkStates() }
        }
        placesPublish()
    }

    /// Regions follow the places while presence is on.
    private func placesWatch() {
        guard pl.store.presenceOn else { return }
        pl.location.syncRegions(pl.store.places)
    }

    // MARK: Presence

    func placesEvent(_ e: PlacesLocation.Event) {
        guard pl.loaded else { return pl.pending.append(e) }
        guard pl.store.presenceOn, !isSample else { return }
        let before = pl.store.visits
        switch e {
        case let .enter(id, at): PlaceLog.enter(id, at: at, source: "region", &pl.store.visits)
        case let .inside(id, at): PlaceLog.enter(id, at: at, source: "state", &pl.store.visits)
        case let .exit(id, at), let .outside(id, at): PlaceLog.exit(id, at: at, &pl.store.visits)
        case let .visit(lat, lon, acc, arrived, departed):
            guard let p = PlaceMatcher.place(latitude: lat, longitude: lon, accuracy: acc, in: pl.store.places) else {
                break
            }
            if let arrived {
                PlaceLog.visit(p.id, arrived: arrived, departed: departed, &pl.store.visits)
            } else if let departed {
                PlaceLog.exit(p.id, at: departed, &pl.store.visits)
            }
        case .problem(let why):
            pl.note = why
        }
        PlaceLog.prune(now: clock.now, &pl.store.visits)
        placesPublish()
        guard pl.store.visits != before else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.placesSave()
            if self.appActive { await self.refresh() }       // a waiting question may now name the place
        }
    }

    /// For the snapshot and the answer handler.
    var placesSnapshot: PlacesSnapshot { isSample ? PlacesSnapshot() : pl.snapshot }

    func placeTag(_ start: Date, _ end: Date) -> PlaceTag? {
        PlacePresence.tag(start: start, end: end, now: clock.now, placesSnapshot)
    }

    /// Where Mo is now (a workout started by hand takes it).
    var placeNow: PlaceTag? { PlacePresence.current(now: clock.now, placesSnapshot) }

    /// A workout event tagged with a place: its name and id (never coordinates), and, when Mo accepted the place's
    /// likely activity, that activity as his own answer. An event that already has a place keeps it.
    static func tagged(_ e: EventRecord, with tag: PlaceTag, acceptActivity: Bool) -> EventRecord {
        var out = e
        if out.location == nil { out.location = EventLocation(label: tag.name, savedPlaceId: tag.placeId) }
        if acceptActivity, let a = tag.likelyActivity, case .workout(var f) = out.payload, f.activityTypeUser == nil {
            f.activityTypeUser = a
            out.payload = .workout(f)
        }
        return out
    }

    func placesPublish() {
        let input = PlacesInput(now: clock.now, calendar: calendar, sample: isSample, places: pl.store.places,
                                visits: pl.store.visits, presenceOn: pl.store.presenceOn,
                                authorization: pl.authorization, note: pl.note)
        let s = PlacesPresenter.make(input)
        if pl.state != s { pl.state = s }
    }
}
