import SwiftUI
import BraincellCore

/// The global Library: every imported file, course folders included.
struct LibraryView: View {
    var body: some View { LibraryBrowser(base: .root, title: "Library") }
}
