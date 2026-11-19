import SwiftUI

/// The slot at the top of a session list (webui and Hermes) that shows at most one card. Empty for
/// now: the tip and star cards linked to the Hermex maintainer, not to Squadd.
struct SessionListCardSlot: View {
    let hasSharedImport: Bool

    var body: some View {
        EmptyView()
    }
}
