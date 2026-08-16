import SwiftUI

/// Two-tab shell: **Ignition** (the live PIG / FFM estimate, including the
/// wet-bulb psychrometrics that used to occupy a third tab) and **Obs** (the
/// shift observation log — the Weather-Watch feature, ``WatchView`` /
/// ``WeatherWatchModel`` internally).
///
/// One tab per question the operator actually asks: *how bad is it right now*
/// and *what does the record say*. That split is also the volatile-vs-frozen
/// line — Ignition's estimate changes with every input, Obs holds readings that
/// have been frozen and broadcast.
///
/// Both tabs share a single ``IgnitionModel`` so the weather the Obs tab freezes
/// is the same weather the operator sees on Ignition — constructed here in
/// `init` because one `@State` can't be initialized from another inline.
@MainActor
struct RootView: View {
    @State private var ignition: IgnitionModel
    @State private var watch: WeatherWatchModel
    @State private var selection: Tab = .ignition
    /// Raised when a deep link wants the Obs tab to open its capture form; the
    /// tab consumes and clears it.
    @State private var startCapture = false
    @Environment(\.scenePhase) private var scenePhase

    enum Tab: Hashable { case ignition, watch }

    /// - Parameter store: where the models persist. Defaults to
    ///   ``AppEnvironment/defaultsStore``, which is `.standard` in normal use and
    ///   a throwaway suite when the UI tests pass their reset flag, so each test
    ///   starts from first-launch defaults instead of inheriting the previous
    ///   test's shift log.
    init(store: UserDefaults = AppEnvironment.defaultsStore) {
        let ignition = IgnitionModel(store: store)
        _ignition = State(initialValue: ignition)
        _watch = State(initialValue: WeatherWatchModel(ignition: ignition, store: store))
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                // The start bar rides the same deep-link path an App Intent
                // uses: land on Obs, then open the capture form — WatchView
                // consumes the flag and honours the site gate, so while gated
                // the tap surfaces the confirm strip instead of the sheet.
                IgnitionView(model: ignition, obsGated: watch.needsSiteConfirmation) {
                    selection = .watch
                    startCapture = true
                }
            }
            .tabItem { Label("Ignition", systemImage: "flame") }
            .tag(Tab.ignition)

            NavigationStack {
                WatchView(model: watch, ignition: ignition, startCapture: $startCapture)
            }
            .tabItem { Label("Obs", systemImage: "binoculars") }
            .tag(Tab.watch)
        }
        .tint(PlateworksColor.accent)
        // An App Intent can ask the app to open on the Obs tab. Consumed once,
        // so returning to the app later doesn't re-navigate.
        .onAppear(perform: consumePendingDeepLink)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { consumePendingDeepLink() }
        }
    }

    private func consumePendingDeepLink() {
        guard let link = AppEnvironment.pendingDeepLink else { return }
        AppEnvironment.pendingDeepLink = nil
        switch link {
        case .logObservation:
            selection = .watch
            // The intent is "log an observation", not "show me the log", so it
            // opens the capture form too. WatchView clears the flag and honours
            // the site gate.
            startCapture = true
        }
    }
}

#Preview {
    RootView()
}
