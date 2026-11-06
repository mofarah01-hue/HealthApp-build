import Foundation

/// T83: the one place the app asks the phone's own language model (Apple's on-device model on iOS 26+ with Apple
/// Intelligence). A hook only: nothing in the app calls it yet and no model is installed. T121's chat window will ask
/// through it; the Apple adapter (FoundationModels) is installed at launch on a phone that has the model (device check).
/// Health data never leaves the phone through this hook; it has no network part.
public protocol OnDeviceModel: Sendable {
    /// The model's reply, or nil when this phone has no usable model right now (older iOS, Apple Intelligence off,
    /// model still downloading).
    func respond(to prompt: String) async throws -> String?
}

public enum OnDeviceAnswer: Equatable, Sendable {
    case answer(String)
    /// No model on this phone right now; the chat falls back to the PC or says so.
    case unavailable
    case failed(String)
}

public actor OnDeviceModelHook {
    private var backend: (any OnDeviceModel)?

    public init() {}

    public func install(_ model: any OnDeviceModel) { backend = model }

    /// Never throws: a model error becomes `.failed` so the chat can show it.
    public func ask(_ prompt: String) async -> OnDeviceAnswer {
        guard let backend else { return .unavailable }
        do {
            guard let text = try await backend.respond(to: prompt) else { return .unavailable }
            return .answer(text)
        } catch {
            return .failed("\(error)")
        }
    }
}
