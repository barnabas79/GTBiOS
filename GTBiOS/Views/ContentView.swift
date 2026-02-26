import SwiftUI

/// Gyökér view: NavigationView a FilePickerView-val és LiveSessionView-val
struct ContentView: View {

    @StateObject private var viewModel = SessionViewModel()

    var body: some View {
        NavigationView {
            FilePickerView(viewModel: viewModel)
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
