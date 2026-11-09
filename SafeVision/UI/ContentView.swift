import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ImageProcessingView()
                .tabItem {
                    Label(localizedKey("tab_image"), systemImage: "photo")
                }
            VideoProcessingView()
                .tabItem {
                    Label(localizedKey("tab_video"), systemImage: "film")
                }
            BatchView()
                .tabItem {
                    Label(localizedKey("tab_batch"), systemImage: "square.stack.3d.up")
                }
            GalleryView()
                .tabItem {
                    Label(localizedKey("tab_gallery"), systemImage: "photo.on.rectangle")
                }
            SettingsView()
                .tabItem {
                    Label(localizedKey("tab_settings"), systemImage: "gearshape")
                }
        }
    }
}
