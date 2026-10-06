import SwiftUI
import AVKit
import UniformTypeIdentifiers

// This tells the iPad this is the starting point of the app
@main
struct VibePlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Models (Stremio Protocol)
struct AddonManifest: Codable {
    let id: String
    let name: String
    let description: String
    let version: String
    let catalogs: [AddonCatalog]?
}

struct AddonCatalog: Codable, Hashable {
    let type: String
    let id: String
    let name: String?
}

struct CatalogResponse: Codable {
    let metas: [CatalogMeta]
}

struct CatalogMeta: Codable, Identifiable {
    let id: String
    let type: String
    let name: String
    let poster: String?
}

struct StreamResponse: Codable {
    let streams: [AddonStream]
}

struct AddonStream: Codable, Identifiable {
    var id: UUID { UUID() }
    let name: String?
    let title: String?
    let url: String?
    let infoHash: String?
}

// MARK: - Main UI
struct ContentView: View {
    var body: some View {
        TabView {
            LocalPlayerView()
                .tabItem { Label("Local Media", systemImage: "folder.fill") }
            
            AddonsView()
                .tabItem { Label("Addons", systemImage: "puzzlepiece.extension") }
        }
    }
}

// MARK: - Tab 1: Local Video Player
struct LocalPlayerView: View {
    @State private var isImporting = false
    @State private var videoURL: URL?
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VStack {
                if let player = player {
                    VideoPlayer(player: player)
                        .edgesIgnoringSafeArea(.all)
                        .onDisappear {
                            player.pause()
                            videoURL?.stopAccessingSecurityScopedResource()
                        }
                } else {
                    ContentUnavailableView(
                        "No Video Selected",
                        systemImage: "film",
                        description: Text("Browse your iPad or iCloud to play a local file.")
                    )
                }
            }
            .navigationTitle("Vibe Player")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open File") { isImporting = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let selectedURL = urls.first else { return }
                    videoURL?.stopAccessingSecurityScopedResource()
                    if selectedURL.startAccessingSecurityScopedResource() {
                        videoURL = selectedURL
                        player = AVPlayer(url: selectedURL)
                        player?.play()
                    }
                case .failure(let error):
                    print("Error: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Tab 2: Addon Manager
struct AddonsView: View {
    @State private var manifestURL = "https://v3-cinemeta.strem.io/manifest.json"
    @State private var addon: AddonManifest?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Install Addon")) {
                    TextField("Manifest URL", text: $manifestURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    
                    Button("Fetch Manifest") {
                        Task { await fetchManifest() }
                    }
                    .disabled(isLoading)
                }
                
                if isLoading {
                    ProgressView("Parsing Addon...")
                } else if let error = errorMessage {
                    Text(error).foregroundColor(.red)
                } else if let addon = addon {
                    Section(header: Text("Installed: \(addon.name)")) {
                        if let catalogs = addon.catalogs, !catalogs.isEmpty {
                            ForEach(catalogs, id: \.self) { catalog in
                                NavigationLink(destination: CatalogGridView(manifestURL: manifestURL, catalog: catalog)) {
                                    VStack(alignment: .leading) {
                                        Text(catalog.name ?? catalog.id.capitalized).font(.headline)
                                        Text("Type: \(catalog.type)").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        } else {
                            Text("No catalogs found in this addon.").foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Addons")
        }
    }
    
    func fetchManifest() async {
        guard let url = URL(string: manifestURL) else {
            errorMessage = "Invalid URL"
            return
        }
        isLoading = true; errorMessage = nil
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            addon = try JSONDecoder().decode(AddonManifest.self, from: data)
        } catch {
            errorMessage = "Failed to parse manifest: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

// MARK: - Catalog Grid View
struct CatalogGridView: View {
    let manifestURL: String
    let catalog: AddonCatalog
    
    @State private var metas: [CatalogMeta] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]
    
    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("Loading \(catalog.type)s...").padding(.top, 50)
            } else if let error = errorMessage {
                Text(error).foregroundColor(.red).padding()
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(metas) { meta in
                        NavigationLink(destination: StreamSelectionView(manifestURL: manifestURL, meta: meta)) {
                            VStack {
                                AsyncImage(url: URL(string: meta.poster ?? "")) { phase in
                                    switch phase {
                                    case .empty: Rectangle().fill(Color.gray.opacity(0.3))
                                    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                                    case .failure: Rectangle().fill(Color.gray.opacity(0.3)).overlay(Image(systemName: "film").foregroundColor(.gray))
                                    @unknown default: EmptyView()
                                    }
                                }
                                .frame(width: 150, height: 225)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(radius: 4)
                                
                                Text(meta.name)
                                    .font(.caption).fontWeight(.semibold)
                                    .lineLimit(2).multilineTextAlignment(.center)
                                    .frame(height: 35)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(catalog.name ?? catalog.id.capitalized)
        .task { await fetchCatalog() }
    }
    
    func fetchCatalog() async {
        let baseURL = manifestURL.replacingOccurrences(of: "/manifest.json", with: "")
        let catalogURLString = "\(baseURL)/catalog/\(catalog.type)/\(catalog.id).json"
        
        guard let url = URL(string: catalogURLString) else {
            errorMessage = "Invalid Catalog URL"; isLoading = false; return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(CatalogResponse.self, from: data)
            self.metas = response.metas
        } catch {
            errorMessage = "Failed to load catalog: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

// MARK: - Stream Selection & Playback
struct StreamSelectionView: View {
    let manifestURL: String
    let meta: CatalogMeta
    
    @State private var streams: [AddonStream] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedStreamURL: URL?

    var body: some View {
        List {
            if isLoading {
                ProgressView("Finding Streams...")
            } else if let error = errorMessage {
                Text(error).foregroundColor(.red)
            } else if streams.isEmpty {
                Text("No streams found for this item.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(streams) { stream in
                    Button(action: {
                        if let urlString = stream.url, let url = URL(string: urlString) {
                            selectedStreamURL = url
                        }
                    }) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(stream.name ?? "Unknown Source")
                                .font(.headline)
                            
                            if let title = stream.title {
                                Text(title)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            if stream.infoHash != nil {
                                Text("Requires Torrent Engine (Not Supported Native)")
                                    .font(.caption).foregroundColor(.orange)
                            } else if stream.url != nil {
                                Text("Direct HTTP/HLS Stream")
                                    .font(.caption).foregroundColor(.green)
                            }
                        }
                    }
                    .disabled(stream.url == nil) 
                }
            }
        }
        .navigationTitle(meta.name)
        .task { await fetchStreams() }
        .fullScreenCover(item: Binding(
            get: { selectedStreamURL.map { IdentifiableURL(url: $0) } },
            set: { selectedStreamURL = $0?.url }
        )) { identURL in
            NativeStreamPlayerView(url: identURL.url)
        }
    }
    
    func fetchStreams() async {
        let baseURL = manifestURL.replacingOccurrences(of: "/manifest.json", with: "")
        let streamURLString = "\(baseURL)/stream/\(meta.type)/\(meta.id).json"
        
        guard let url = URL(string: streamURLString) else {
            errorMessage = "Invalid Stream URL"; isLoading = false; return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(StreamResponse.self, from: data)
            self.streams = response.streams
        } catch {
            errorMessage = "Failed to load streams: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct NativeStreamPlayerView: View {
    let url: URL
    @Environment(\.dismiss) var dismiss
    @State private var player: AVPlayer?
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if let player = player {
                VideoPlayer(player: player)
                    .edgesIgnoringSafeArea(.all)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            }
            
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.white)
                    .padding()
            }
        }
        .onAppear {
            self.player = AVPlayer(url: url)
        }
    }
}
