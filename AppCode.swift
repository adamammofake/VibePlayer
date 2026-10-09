import SwiftUI
import AVKit
import UniformTypeIdentifiers

// MARK: - App Entry & Storage
@main
struct VibePlayerApp: App {
    @StateObject var addonStore = AddonStore()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(addonStore)
        }
    }
}

class AddonStore: ObservableObject {
    @Published var savedManifests: [String] = []
    
    init() {
        if let data = UserDefaults.standard.data(forKey: "savedManifests"),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            savedManifests = decoded
        } else {
            savedManifests = ["https://v3-cinemeta.strem.io/manifest.json"]
        }
    }
    
    func add(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !savedManifests.contains(trimmed) {
            savedManifests.append(trimmed)
            save()
        }
    }
    
    func remove(at offsets: IndexSet) {
        savedManifests.remove(atOffsets: offsets)
        save()
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(savedManifests) {
            UserDefaults.standard.set(encoded, forKey: "savedManifests")
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
            
            AddonsManagerView()
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
struct AddonsManagerView: View {
    @EnvironmentObject var addonStore: AddonStore
    @State private var newManifestURL = ""

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Add New Addon")) {
                    HStack {
                        TextField("Manifest URL (e.g. https://.../manifest.json)", text: $newManifestURL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                        
                        Button("Save") {
                            addonStore.add(newManifestURL)
                            newManifestURL = ""
                        }
                        .disabled(newManifestURL.isEmpty)
                    }
                }
                
                Section(header: Text("Saved Addons")) {
                    if addonStore.savedManifests.isEmpty {
                        Text("No addons saved yet.").foregroundColor(.secondary)
                    } else {
                        ForEach(addonStore.savedManifests, id: \.self) { url in
                            NavigationLink(destination: AddonDetailView(manifestURL: url)) {
                                Text(url).lineLimit(1)
                            }
                        }
                        .onDelete(perform: addonStore.remove)
                    }
                }
            }
            .navigationTitle("Addons")
        }
    }
}

// MARK: - Addon Detail
struct AddonDetailView: View {
    let manifestURL: String
    
    @State private var addon: AddonManifest?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading Addon...")
            } else if let error = errorMessage {
                Text(error).foregroundColor(.red)
            } else if let addon = addon {
                Section(header: Text("Addon Info")) {
                    VStack(alignment: .leading) {
                        Text(addon.name).font(.headline)
                        Text(addon.description).font(.subheadline).foregroundColor(.secondary)
                        Text("Version \(addon.version)").font(.caption).foregroundColor(.gray)
                    }
                }
                
                Section(header: Text("Catalogs")) {
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
                        Text("No catalogs found.").foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Addon Details")
        .task { await fetchManifest() }
    }
    
    func fetchManifest() async {
        guard let url = URL(string: manifestURL) else {
            errorMessage = "Invalid URL"; isLoading = false; return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            addon = try JSONDecoder().decode(AddonManifest.self, from: data)
        } catch {
            errorMessage = "Failed to parse manifest: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

// MARK: - Catalog Grid (With Search)
struct CatalogGridView: View {
    let manifestURL: String
    let catalog: AddonCatalog
    
    @State private var metas: [CatalogMeta] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    
    let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]
    
    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("Loading...").padding(.top, 50)
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
        .searchable(text: $searchText, prompt: "Search \(catalog.type)s...")
        .onSubmit(of: .search) {
            Task { await fetchCatalog() }
        }
        .onChange(of: searchText) { newValue in
            if newValue.isEmpty { Task { await fetchCatalog() } }
        }
        .task { await fetchCatalog() }
    }
    
    func fetchCatalog() async {
        isLoading = true
        errorMessage = nil
        let baseURL = manifestURL.replacingOccurrences(of: "/manifest.json", with: "")
        
        var catalogURLString = ""
        if !searchText.isEmpty, let encodedQuery = searchText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            catalogURLString = "\(baseURL)/catalog/\(catalog.type)/\(catalog.id)/search=\(encodedQuery).json"
        } else {
            catalogURLString = "\(baseURL)/catalog/\(catalog.type)/\(catalog.id).json"
        }
        
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

// MARK: - Stream Selection
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
                            Text(stream.title ?? stream.name ?? "Unknown Source")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            if stream.infoHash != nil {
                                Text("Requires Torrent Engine (Not Supported Native)")
                                    .font(.caption).foregroundColor(.orange)
                            } else if stream.url != nil {
                                Text("Direct Stream Ready")
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
            NativeStreamPlayerView(
                currentURL: identURL.url,
                availableStreams: streams.filter { $0.url != nil }
            )
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

// MARK: - Video Player (With Advanced Quality Selection)
struct NativeStreamPlayerView: View {
    @State var currentURL: URL
    let availableStreams: [AddonStream]
    
    @Environment(\.dismiss) var dismiss
    @State private var player: AVPlayer?
    
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if let player = player {
                VideoPlayer(player: player)
                    .edgesIgnoringSafeArea(.all)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            }
            
            // Top Controls Overlay
            HStack {
                Spacer()
                
                // Quality Selection Menu
                Menu {
                    Section("Switch Addon Link") {
                        ForEach(availableStreams) { stream in
                            if let urlString = stream.url, let url = URL(string: urlString) {
                                Button(stream.title ?? stream.name ?? "Standard Quality") {
                                    changeStreamSource(to: url)
                                }
                            }
                        }
                    }
                    
                    Section("Force HLS Resolution") {
                        Button("Auto") { forceResolution(width: 0, height: 0) }
                        Button("1080p") { forceResolution(width: 1920, height: 1080) }
                        Button("720p") { forceResolution(width: 1280, height: 720) }
                        Button("480p") { forceResolution(width: 854, height: 480) }
                    }
                } label: {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                        Text("Quality")
                    }
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Capsule())
                }
                
                // Close Button
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundColor(.white)
                        .padding(.leading, 8)
                        .shadow(radius: 2)
                }
            }
            .padding(.top, 20)
            .padding(.trailing, 20)
        }
        .onAppear {
            self.player = AVPlayer(url: currentURL)
        }
    }
    
    // Swaps to a completely different stream link from the addon
    func changeStreamSource(to newURL: URL) {
        currentURL = newURL
        let currentTime = player?.currentTime() ?? .zero
        player?.pause()
        let newItem = AVPlayerItem(url: newURL)
        player?.replaceCurrentItem(with: newItem)
        player?.seek(to: currentTime)
        player?.play()
    }
    
    // Forces the current stream to drop or rise to a specific quality
    func forceResolution(width: CGFloat, height: CGFloat) {
        player?.currentItem?.preferredMaximumResolution = CGSize(width: width, height: height)
    }
}
