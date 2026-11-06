import Foundation

/// Settings › Command test (T87, 2026-10-13). Sent as `UIIntent.commandTest(_:)`.
public enum CommandTestMark: String, CaseIterable, Equatable, Sendable {
    case worked, nothing, red
}

public enum CommandTestAction: Equatable, Sendable {
    /// Settings row: push the page (it loads the saved log).
    case open
    /// The optional payload field, as typed (hex, spaces allowed).
    case setPayload(String)
    /// One command at a time. `on: true` sends that command once (the row's Send button; r8h C1); `on: false` only clears
    /// the "last sent" mark (nothing is sent). A second send while one is in flight is ignored.
    case toggle(number: Int, on: Bool)
    /// The result picker next to a log row.
    case mark(entryID: Int64, CommandTestMark)
    /// Raw optical (PPG) section (P9726): the Settings "Raw optical" switch itself (108 through the app's managed path).
    case setRawOptical(Bool)
    /// What Mo saw; saved against the newest send in the log.
    case observe(PPGObservation)
    /// T124 motion polling: bursts or continuous raw motion while chosen (not saved).
    case setMotionPolling(MotionPolling)
    /// "Record all night": ENABLE_OPTICAL_DATA [01 01] / [01 00], sent once and logged.
    case setNightBanking(Bool)
    /// T9992: "Keep raw on the strap if the app is closed": the saved switch (107 while raw optical is on, sent again after a
    /// reconnect). Default off.
    case setKeepRawOnStrap(Bool)
}
