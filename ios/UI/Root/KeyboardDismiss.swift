import SwiftUI
import UIKit

// T9746 (Mo 2026-10-14: "the keyboard does not dismiss when tapping outside"). ONE shared modifier, applied once at the
// root: a tap anywhere that is not a text field puts the keyboard away, and so does scrolling (`scrollDismissesKeyboard`,
// which every ScrollView below inherits through the environment, sheets and covers included).
//
// The tap is a window-level recognizer that does not cancel the touch, so buttons and rows still work, and it ignores
// touches that land in a text field or text view, so tapping a field still focuses it.
//
// WRITTEN, NOT COMPILED.

extension View {
    /// Tap outside a text field and scroll both dismiss the keyboard. Apply once, at the root.
    func dismissesKeyboardOnTapOrScroll() -> some View {
        modifier(DismissKeyboardModifier())
    }
}

/// r8h K1: put the keyboard away from code (a Return key, a Done button).
enum KeyboardFocus {
    static func resign() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// r9v (K1): the text field or text view after the focused one on the same screen (top to bottom, then left to
    /// right), or nil when the focused one is the last. Only fields that exist right now are seen (a lazy list's
    /// off-screen rows are not built), so the last visible field says Done.
    @MainActor static func nextField() -> UIView? {
        var focused: UIView?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                focused = firstResponderField(in: window)
            }
        }
        guard let focused else { return nil }
        // Stay inside the focused field's own screen: a sheet's fields, not the page under it.
        var root: UIView = focused
        var responder: UIResponder? = focused
        while let r = responder {
            if let vc = r as? UIViewController { root = vc.view; break }
            responder = r.next
        }
        var fields: [UIView] = []
        collect(in: root, into: &fields)
        let ordered = fields.sorted {
            let a = $0.convert($0.bounds.origin, to: nil), b = $1.convert($1.bounds.origin, to: nil)
            return a.y == b.y ? a.x < b.x : a.y < b.y
        }
        guard let i = ordered.firstIndex(of: focused), i + 1 < ordered.count else { return nil }
        return ordered[i + 1]
    }

    /// The Return key: on to the next field, or put the keyboard away after the last one.
    @MainActor static func advance() {
        if let next = nextField() { next.becomeFirstResponder() } else { resign() }
    }

    @MainActor private static func firstResponderField(in view: UIView) -> UIView? {
        if (view is UITextField || view is UITextView), view.isFirstResponder { return view }
        for sub in view.subviews { if let hit = firstResponderField(in: sub) { return hit } }
        return nil
    }

    @MainActor private static func collect(in view: UIView, into out: inout [UIView]) {
        if (view is UITextField || view is UITextView), !view.isHidden, view.alpha > 0.01, view.window != nil {
            out.append(view)
        }
        for sub in view.subviews { collect(in: sub, into: &out) }
    }
}

/// r9v (K1): the Return key of a single-line field says Next while another field follows it on the screen and Done on
/// the last one; it moves on or closes the keyboard. Apply to a field that has no `.focused` of its own.
struct FormSubmitModifier: ViewModifier {
    @FocusState private var focused: Bool
    @State private var isLast = true

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .submitLabel(isLast ? .done : .next)
            .onChange(of: focused) { _, now in
                guard now else { return }
                // After UIKit has made it first responder.
                Task { @MainActor in isLast = KeyboardFocus.nextField() == nil }
            }
            .onSubmit { KeyboardFocus.advance() }
    }
}

extension View {
    func formSubmit() -> some View { modifier(FormSubmitModifier()) }
}

extension View {
    /// r8h G2/K1: a "Done" key above the keyboard. One modifier for every form (numeric pads have no Return key).
    func keyboardDoneBar() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { KeyboardFocus.resign() }
            }
        }
    }

    /// r8h K1: mark a multi-field form. While one is on screen a tap between two fields does NOT drop the keyboard
    /// (it would reopen for every field); scrolling (interactive) and the Done key still do. Also scrolls interactively.
    func formScope() -> some View {
        modifier(FormScopeModifier())
    }
}

struct FormScopeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .onAppear { KeyboardTapDismisser.shared.formScopeDepth += 1 }
            .onDisappear { KeyboardTapDismisser.shared.formScopeDepth = max(0, KeyboardTapDismisser.shared.formScopeDepth - 1) }
    }
}

struct DismissKeyboardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.immediately)
            .onAppear { KeyboardTapDismisser.shared.installOnWindows() }
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { _ in
                KeyboardTapDismisser.shared.installOnWindows()
            }
    }
}

final class KeyboardTapDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardTapDismisser()
    private static let name = "mg.dismissKeyboardOnTap"
    /// r8h K1: how many `.formScope()` forms are on screen; above 0 a tap outside a field leaves the keyboard alone.
    var formScopeDepth = 0

    /// Round 5 (review item 8): the keyboard and the text-effects layer are windows of their own (UIRemoteKeyboardWindow,
    /// UITextEffectsWindow). A recognizer on those would fire on key taps, so only the app's own KEY window gets one.
    static func isSystemWindow(_ window: UIWindow?) -> Bool {
        guard let window else { return false }
        let name = String(describing: type(of: window))
        return name.contains("Keyboard") || name.contains("TextEffects") || name.contains("RemoteKeyboard")
    }

    func installOnWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.isKeyWindow && !Self.isSystemWindow(window)
                && !(window.gestureRecognizers ?? []).contains(where: { $0.name == Self.name }) {
                let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
                tap.name = Self.name
                tap.cancelsTouchesInView = false
                tap.delegate = self
                window.addGestureRecognizer(tap)
            }
        }
    }

    @objc private func tapped() {
        KeyboardFocus.resign()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if Self.isSystemWindow(touch.window) { return false }
        if formScopeDepth > 0 { return false }
        var view = touch.view
        while let v = view {
            if v is UITextField || v is UITextView { return false }
            view = v.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
