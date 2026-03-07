import SwiftUI

struct StatusItemIcon: View {
    let status: ConnectionStatus

    var body: some View {
        Image(systemName: status.systemImage)
            .symbolRenderingMode(.hierarchical)
    }
}
