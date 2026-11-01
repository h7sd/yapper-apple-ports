import SwiftUI

@main
struct YapperNativeApp: App {
    @State private var store: NativeStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        OriginalYapper.registerFonts()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--native-ui-fixtures") {
            _store = State(initialValue: NativeStore.fixture(signedIn: !arguments.contains("--native-ui-login-fixture")))
        } else {
            _store = State(initialValue: NativeStore())
        }
        #else
        _store = State(initialValue: NativeStore())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            NativeRootView(store: store)
                .font(OriginalYapper.font(15))
                .onChange(of: scenePhase) { _, phase in
                    store.setActive(phase == .active)
                }
        }
    }
}
