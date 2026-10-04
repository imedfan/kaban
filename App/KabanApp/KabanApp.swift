import SwiftUI
import KabanBoardCore

@main struct KabanApp: App {
    @State private var store = BoardStore(client: MockKabanClient())
    var body: some Scene {
        WindowGroup {
            BoardView(store: store)
                .frame(minWidth: 1040, minHeight: 640)
                .task { await store.connect() }
        }
        .defaultSize(width: 1440, height: 860)
    }
}
