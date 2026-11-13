import AVFoundation
import AVKit
import CoreMedia
import MediaPlayer
import Observation
import SwiftUI
import UIKit

struct Playlist: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var trackFileNames: [String]

    init(id: UUID = UUID(), name: String, trackFileNames: [String] = []) {
        self.id = id
        self.name = name
        self.trackFileNames = trackFileNames
    }
}

@MainActor
@Observable
private final class PurerifyModel {
    var link = ""
    var serverBaseURL: String = ServerConverter.baseURLString {
        didSet { ServerConverter.setBaseURL(serverBaseURL) }
    }
    var resolvedVideo: ResolvedVideo?
    var savedFileURL: URL?
    var isResolving = false
    var isDownloading = false
    var isPlaying = false
    var errorMessage: String?
    var player: AVPlayer?
    var playbackTime: Double = 0
    var playbackDuration: Double = 0
    private var timeObserver: Any?
    private var remoteCommandsConfigured = false
    private var interruptionObserverConfigured = false
    var library: [SavedAudio] = []
    var playlists: [Playlist] = []

    enum RepeatMode { case off, all, one }
    var repeatMode: RepeatMode = .off
    var isShuffle: Bool = false
    var playQueue: [SavedAudio] = []
    var queueIndex: Int = 0

    // Spotify import state
    var spotifyImportTracks: [SpotifyImportTrack] = []
    var spotifyImportName: String?
    var isImportingSpotify = false
    var spotifyImportError: String?
    var spotifyImportProgress: Double = 0

    init() {
        refreshLibrary()
        loadPlaylists()
        configureAudioSession()
    }

    func resolve() async {
        errorMessage = nil
        resolvedVideo = nil
        savedFileURL = nil
        isResolving = true
        defer { isResolving = false }

        do {
            resolvedVideo = try await ServerConverter.convert(link)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download() async {
        guard let resolvedVideo else { return }
        errorMessage = nil
        isDownloading = true
        defer { isDownloading = false }

        do {
            let fileURL = try Self.libraryDirectory().appendingPathComponent(
                "\(Self.safeFileName(resolvedVideo.title))-\(resolvedVideo.id).m4a"
            )
            try await AudioDownloader.download(
                resolvedVideo,
                to: fileURL,
                input: link.isEmpty ? "https://youtu.be/\(resolvedVideo.id)" : link
            )
            savedFileURL = fileURL
            refreshLibrary()
        } catch {
            if let urlError = error as? URLError {
                errorMessage = "Download failed (URLError \(urlError.code.rawValue)): \(urlError.localizedDescription)"
            } else {
                errorMessage = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    private func downloadViaWebPlayer(_ video: ResolvedVideo, to fileURL: URL) async throws {
        let audioURL = try await WebStreamCapture.captureAudioURL(videoID: video.id)
        let clen = URLComponents(url: audioURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "clen" })?.value.flatMap { Int($0) }
        let webVideo = ResolvedVideo(
            id: video.id,
            title: video.title,
            author: video.author,
            audioURL: audioURL,
            audioBitrate: video.audioBitrate,
            contentLength: clen,
            userAgent: WebStreamCapture.userAgent,
            clientName: "web player",
            isWebStream: true
        )
        try await AudioDownloader.download(webVideo, to: fileURL, input: "https://youtu.be/\(video.id)")
    }

    func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else if let savedFileURL {
            if player == nil {
                attachPlayer(to: savedFileURL)
            }
            player?.play()
            isPlaying = true
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // Ignore; playback may still work with system defaults.
        }

        UIApplication.shared.beginReceivingRemoteControlEvents()

        guard !interruptionObserverConfigured else { return }
        interruptionObserverConfigured = true

        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    if self?.isPlaying == true {
                        try? AVAudioSession.sharedInstance().setActive(true, options: [])
                        self?.player?.play()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == true {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self?.player?.play()
                    self?.updateNowPlaying()
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            if type == .ended {
                try? AVAudioSession.sharedInstance().setActive(true)
                Task { @MainActor in
                    self?.player?.play()
                    self?.isPlaying = true
                    self?.updateNowPlaying()
                }
            }
        }
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.play(); self?.isPlaying = true; self?.updateNowPlaying() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.pause(); self?.isPlaying = false; self?.updateNowPlaying() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback(); self?.updateNowPlaying() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                Task { @MainActor in self?.seek(to: e.positionTime); self?.updateNowPlaying() }
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let player else { return }
        var info: [String: Any] = [:]
        let title = savedFileURL?.deletingPathExtension().lastPathComponent ?? "Purerify"
        info[MPMediaItemPropertyTitle] = title
        if let dur = player.currentItem?.duration.seconds, dur.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = dur
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func attachPlayer(to url: URL) {
        configureAudioSession()
        if let old = player { removeTimeObserver(from: old) }
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        playbackTime = 0
        playbackDuration = 0
        addTimeObserver(to: newPlayer)
        configureRemoteCommands()
        updateNowPlaying()
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTrackEnd()
            }
        }
    }

    private func addTimeObserver(to player: AVPlayer) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.playbackTime = time.seconds
                if let dur = player.currentItem?.duration.seconds, dur.isFinite {
                    self.playbackDuration = dur
                }
                if player.timeControlStatus == .playing {
                    self.isPlaying = true
                }
                self.updateNowPlaying()
            }
        }
    }

    private func removeTimeObserver(from player: AVPlayer) {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time)
        playbackTime = seconds
    }

    func play(_ audio: SavedAudio, queue: [SavedAudio]? = nil) {
        if let queue { playQueue = queue }
        if playQueue.isEmpty { playQueue = [audio] }
        if let idx = playQueue.firstIndex(where: { $0.id == audio.id }) {
            queueIndex = idx
        } else {
            playQueue = [audio]
            queueIndex = 0
        }

        player?.pause()
        if let old = player { removeTimeObserver(from: old) }
        savedFileURL = audio.url
        attachPlayer(to: audio.url)
        player?.play()
        isPlaying = true
        updateNowPlaying()
    }

    func toggleShuffle() {
        isShuffle.toggle()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func playNext() {
        guard !playQueue.isEmpty else { return }
        var idx = queueIndex + 1
        if idx >= playQueue.count {
            guard repeatMode == .all else { return }
            idx = 0
        }
        play(playQueue[idx], queue: playQueue)
    }

    func playPrevious() {
        guard !playQueue.isEmpty else { return }
        if playbackTime > 3 {
            player?.seek(to: .zero)
            playbackTime = 0
            updateNowPlaying()
            return
        }
        var idx = queueIndex - 1
        if idx < 0 {
            guard repeatMode == .all else { return }
            idx = playQueue.count - 1
        }
        play(playQueue[idx], queue: playQueue)
    }

    func handleTrackEnd() {
        if repeatMode == .one {
            player?.seek(to: .zero)
            player?.play()
            playbackTime = 0
            isPlaying = true
            updateNowPlaying()
            return
        }

        guard !playQueue.isEmpty else {
            isPlaying = false
            playbackTime = 0
            player?.seek(to: .zero)
            return
        }

        var nextIndex: Int?
        if isShuffle {
            if playQueue.count > 1 {
                var candidate = queueIndex
                while candidate == queueIndex {
                    candidate = Int.random(in: 0..<playQueue.count)
                }
                nextIndex = candidate
            } else {
                nextIndex = queueIndex
            }
        } else {
            let candidate = queueIndex + 1
            if candidate < playQueue.count {
                nextIndex = candidate
            } else if repeatMode == .all {
                nextIndex = 0
            }
        }

        if let idx = nextIndex {
            play(playQueue[idx], queue: playQueue)
        } else {
            isPlaying = false
            playbackTime = 0
            player?.seek(to: .zero)
            updateNowPlaying()
        }
    }

    private static func playlistsFileURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("PurerifyLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        let url = directory.appendingPathComponent("playlists.json")
        return url
    }

    private func loadPlaylists() {
        guard let url = try? Self.playlistsFileURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else {
            playlists = []
            return
        }
        playlists = decoded
    }

    private func savePlaylists() {
        guard let url = try? Self.playlistsFileURL(),
              let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func createPlaylist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists.append(Playlist(name: trimmed))
        savePlaylists()
    }

    func deletePlaylist(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists[idx].name = trimmed
        savePlaylists()
    }

    func addTrack(_ audio: SavedAudio, to playlist: Playlist) {
        guard let pIdx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let fileName = audio.url.lastPathComponent
        if !playlists[pIdx].trackFileNames.contains(fileName) {
            playlists[pIdx].trackFileNames.append(fileName)
            savePlaylists()
        }
    }

    func removeTrack(at offsets: IndexSet, from playlist: Playlist) {
        guard let pIdx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[pIdx].trackFileNames.remove(atOffsets: offsets)
        savePlaylists()
    }

    func tracks(for playlist: Playlist) -> [SavedAudio] {
        playlist.trackFileNames.compactMap { name in
            library.first { $0.url.lastPathComponent == name }
        }
    }

    func importSpotifyPlaylist(url: String) async {
        isImportingSpotify = true
        spotifyImportError = nil
        spotifyImportTracks = []
        spotifyImportProgress = 0
        defer { isImportingSpotify = false }

        do {
            let playlist = try await ServerConverter.fetchSpotifyPlaylist(url)
            spotifyImportName = playlist.name
            spotifyImportTracks = playlist.tracks.map { SpotifyImportTrack(title: $0.title, artist: $0.artist) }
            createPlaylist(named: playlist.name)
            let nativePlaylistID = playlists.last?.id
            let total = max(spotifyImportTracks.count, 1)

            for i in spotifyImportTracks.indices {
                spotifyImportTracks[i].status = .matching
                let query = "\\(spotifyImportTracks[i].artist) - \\(spotifyImportTracks[i].title)"
                let searchResult: YouTubeSearchResult
                do {
                    searchResult = try await ServerConverter.searchYouTube(query: query)
                } catch {
                    spotifyImportTracks[i].status = .failed
                    spotifyImportTracks[i].errorMessage = error.localizedDescription
                    spotifyImportProgress = Double(i + 1) / Double(total)
                    continue
                }

                spotifyImportTracks[i].status = .downloading
                do {
                    let video = try await ServerConverter.convert(searchResult.url)
                    let fileURL = try Self.libraryDirectory().appendingPathComponent(
                        "\(Self.safeFileName(video.title))-\(video.id).m4a"
                    )
                    try await AudioDownloader.download(video, to: fileURL, input: searchResult.url)
                    spotifyImportTracks[i].savedFileName = fileURL.lastPathComponent
                    spotifyImportTracks[i].status = .done
                    refreshLibrary()
                    if let nativePlaylistID,
                       let pIndex = playlists.firstIndex(where: { $0.id == nativePlaylistID }) {
                        if !playlists[pIndex].trackFileNames.contains(fileURL.lastPathComponent) {
                            playlists[pIndex].trackFileNames.append(fileURL.lastPathComponent)
                            savePlaylists()
                        }
                    }
                } catch {
                    spotifyImportTracks[i].status = .failed
                    spotifyImportTracks[i].errorMessage = error.localizedDescription
                }
                spotifyImportProgress = Double(i + 1) / Double(total)
            }
        } catch {
            spotifyImportError = error.localizedDescription
        }
    }

    private func refreshLibrary() {
        guard let directory = try? Self.libraryDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else {
            library = []
            return
        }

        library = files
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                let title = String(name.dropLast(12)).trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
                return SavedAudio(url: url, title: title.isEmpty ? name : title)
            }

        // Drop tracks that no longer exist from playlists.
        let existing = Set(library.map { $0.url.lastPathComponent })
        var changed = false
        for i in playlists.indices {
            let before = playlists[i].trackFileNames.count
            playlists[i].trackFileNames = playlists[i].trackFileNames.filter { existing.contains($0) }
            if playlists[i].trackFileNames.count != before { changed = true }
        }
        if changed { savePlaylists() }
    }

    private static func libraryDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("PurerifyLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: support.path
        )
        return directory
    }

    func delete(_ audio: SavedAudio) {
        try? FileManager.default.removeItem(at: audio.url)
        if savedFileURL == audio.url {
            player?.pause()
            player = nil
            savedFileURL = nil
            isPlaying = false
            playbackTime = 0
            playbackDuration = 0
        }
        refreshLibrary()
    }

    private static func safeFileName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = title.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "YouTube-audio" : trimmed).prefix(70))
    }
}

private struct SavedAudio: Identifiable {
    let url: URL
    let title: String

    var id: URL { url }
}

enum SpotifyImportStatus: String {
    case pending, matching, downloading, done, failed
}

struct SpotifyImportTrack: Identifiable {
    let id = UUID()
    let title: String
    let artist: String
    var status: SpotifyImportStatus = .pending
    var savedFileName: String?
    var errorMessage: String?
}

struct ContentView: View {
    @State private var model = PurerifyModel()
    @State private var selectedTab = 0
    @State private var showNowPlaying = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView(model: model)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(0)

                LibraryView(model: model, showNowPlaying: $showNowPlaying)
                    .tabItem { Label("Library", systemImage: "music.note.list") }
                    .tag(1)
            }
            .tint(Color(red: 0.11, green: 0.73, blue: 0.33))

            if model.savedFileURL != nil {
                MiniPlayer(model: model, showNowPlaying: $showNowPlaying)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 52)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.savedFileURL)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(model: model)
        }
    }
}

// MARK: - Home

private struct HomeView: View {
    @Bindable var model: PurerifyModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    serverCard

                    inputCard

                    if model.isResolving {
                        ProgressView("Checking video…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tint(.white)
                    }

                    if let video = model.resolvedVideo {
                        videoCard(video)
                    }

                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    }

                    Text("Only save content you own or have permission to download.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .padding(20)
            }
            .background(Color.black)
            .navigationTitle("Purerify")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Purerify")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Paste a YouTube link to save audio offline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SERVER")
                .font(.caption.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            TextField("https://192.168.1.6:8443", text: $model.serverBaseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
        }
        .padding(16)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUTUBE LINK")
                    .font(.caption.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Paste") {
                    if let clipboard = UIPasteboard.general.string {
                        model.link = clipboard
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
            }

            TextField("youtube.com/watch?v=…", text: $model.link, axis: .vertical)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...3)
                .padding(12)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)

            Button {
                Task { await model.resolve() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.to.line")
                    Text("Find audio")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.black)
                .background(Color(red: 0.11, green: 0.73, blue: 0.33), in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(model.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isResolving)
            .opacity(model.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
        }
        .padding(16)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func videoCard(_ video: ResolvedVideo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(white: 0.15))
                    .frame(width: 60, height: 60)
                    .overlay(Image(systemName: "music.note").font(.title2).foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(video.author.isEmpty ? "YouTube" : video.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack {
                Label("AAC · M4A", systemImage: "waveform")
                Spacer()
                if let bitrate = video.audioBitrate {
                    Text("\(bitrate / 1000) kbps")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            if model.savedFileURL != nil {
                VStack(spacing: 12) {
                    Slider(value: $model.playbackTime, in: 0...max(model.playbackDuration, 1), onEditingChanged: { editing in
                        if !editing { model.seek(to: model.playbackTime) }
                    })
                    .tint(Color(red: 0.11, green: 0.73, blue: 0.33))

                    HStack {
                        Text(formatTime(model.playbackTime))
                        Spacer()
                        Text(formatTime(model.playbackDuration))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button(action: model.togglePlayback) {
                        Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.black)
                            .background(Color(red: 0.11, green: 0.73, blue: 0.33), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else {
                Button {
                    Task { await model.download() }
                } label: {
                    HStack {
                        if model.isDownloading {
                            ProgressView().tint(.black)
                            Text("Saving audio…")
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Save for offline")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.black)
                    .background(Color(red: 0.11, green: 0.73, blue: 0.33), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(model.isDownloading)
            }
        }
        .padding(18)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Library

private struct LibraryView: View {
    @Bindable var model: PurerifyModel
    @Binding var showNowPlaying: Bool
    @State private var isEditing = false
    @State private var showCreatePlaylist = false
    @State private var showSpotifyImport = false
    @State private var newPlaylistName = ""
    @State private var playlistToAddTo: Playlist?

    var body: some View {
        NavigationStack {
            Group {
                if model.library.isEmpty && model.playlists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No saved music yet")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Download audio from the Home tab and it will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List {
                        if !model.playlists.isEmpty {
                            Section("Playlists") {
                                ForEach(model.playlists) { playlist in
                                    NavigationLink(value: playlist) {
                                        HStack(spacing: 12) {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(white: 0.15))
                                                .frame(width: 48, height: 48)
                                                .overlay(Image(systemName: "music.note.list").foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33)))
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(playlist.name)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                Text("\(model.tracks(for: playlist).count) songs")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .padding(.vertical, 6)
                                    }
                                    .listRowBackground(Color.black)
                                }
                            }
                        }

                        Section("Songs") {
                            ForEach(model.library) { audio in
                                HStack(spacing: 12) {
                                    if isEditing {
                                        Button {
                                            model.delete(audio)
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    Button {
                                        if !isEditing {
                                            model.play(audio, queue: model.library)
                                            showNowPlaying = true
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(white: 0.15))
                                                .frame(width: 48, height: 48)
                                                .overlay(Image(systemName: "music.note").foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33)))
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(audio.title)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                Text("Offline · M4A")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if !isEditing {
                                                Image(systemName: "play.circle.fill")
                                                    .font(.title2)
                                                    .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        ForEach(model.playlists) { pl in
                                            Button {
                                                model.addTrack(audio, to: pl)
                                            } label: {
                                                Label("Add to \(pl.name)", systemImage: "plus")
                                            }
                                        }
                                        if model.playlists.isEmpty {
                                            Button {
                                                showCreatePlaylist = true
                                            } label: {
                                                Label("Create playlist", systemImage: "plus")
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                                .listRowBackground(Color.black)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.black)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showCreatePlaylist = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSpotifyImport = true
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isEditing.toggle()
                    } label: {
                        Image(systemName: isEditing ? "checkmark.circle.fill" : "slider.horizontal.3")
                            .font(.title2)
                            .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                    }
                }
            }
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(model: model, playlist: playlist, showNowPlaying: $showNowPlaying)
            }
            .sheet(isPresented: $showSpotifyImport) {
                SpotifyImportView(model: model)
            }
            .sheet(isPresented: $showCreatePlaylist) {
                NavigationStack {
                    Form {
                        TextField("Playlist name", text: $newPlaylistName)
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.black)
                    .navigationTitle("New Playlist")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                newPlaylistName = ""
                                showCreatePlaylist = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Create") {
                                model.createPlaylist(named: newPlaylistName)
                                newPlaylistName = ""
                                showCreatePlaylist = false
                            }
                            .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .preferredColorScheme(.dark)
            }
        }
    }
}

private struct PlaylistDetailView: View {
    @Bindable var model: PurerifyModel
    let playlist: Playlist
    @Binding var showNowPlaying: Bool
    @State private var isEditing = false

    var currentPlaylist: Playlist {
        model.playlists.first { $0.id == playlist.id } ?? playlist
    }

    var body: some View {
        List {
            let tracks = model.tracks(for: currentPlaylist)
            if tracks.isEmpty {
                Text("No songs in this playlist yet. Long-press a song in Library and choose Add to Playlist.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.black)
            } else {
                ForEach(tracks) { audio in
                    HStack(spacing: 12) {
                        if isEditing {
                            Button {
                                if let idx = currentPlaylist.trackFileNames.firstIndex(of: audio.url.lastPathComponent) {
                                    model.removeTrack(at: IndexSet(integer: idx), from: currentPlaylist)
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            if !isEditing {
                                model.play(audio, queue: model.tracks(for: currentPlaylist))
                                showNowPlaying = true
                            }
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(white: 0.15))
                                    .frame(width: 48, height: 48)
                                    .overlay(Image(systemName: "music.note").foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33)))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(audio.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text("Offline · M4A")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !isEditing {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.black)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle(currentPlaylist.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isEditing.toggle()
                } label: {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "slider.horizontal.3")
                        .font(.title2)
                        .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                }
            }
        }
    }
}

// MARK: - Mini Player

private struct MiniPlayer: View {
    @Bindable var model: PurerifyModel
    @Binding var showNowPlaying: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.playbackDuration > 0 {
                ProgressView(value: model.playbackTime, total: model.playbackDuration)
                    .tint(Color(red: 0.11, green: 0.73, blue: 0.33))
                    .scaleEffect(x: 1, y: 0.5, anchor: .center)
            }
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.15))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "music.note").foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Purerify")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture { showNowPlaying = true }
        }
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }

    private var currentTitle: String {
        if let url = model.savedFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return "Now Playing"
    }
}

// MARK: - Now Playing

private struct NowPlayingView: View {
    @Bindable var model: PurerifyModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(white: 0.15))
                    .frame(width: 260, height: 260)
                    .overlay(Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33)))

                VStack(spacing: 6) {
                    Text(currentTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("Purerify")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    Slider(value: $model.playbackTime, in: 0...max(model.playbackDuration, 1), onEditingChanged: { editing in
                        if !editing { model.seek(to: model.playbackTime) }
                    })
                    .tint(Color(red: 0.11, green: 0.73, blue: 0.33))

                    HStack {
                        Text(formatTime(model.playbackTime))
                        Spacer()
                        Text(formatTime(model.playbackDuration))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)

                HStack(spacing: 28) {
                    Button(action: model.toggleShuffle) {
                        Image(systemName: "shuffle")
                            .font(.title2)
                            .foregroundStyle(model.isShuffle ? Color(red: 0.11, green: 0.73, blue: 0.33) : .white)
                    }

                    Button(action: model.playPrevious) {
                        Image(systemName: "backward.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }

                    Button(action: model.togglePlayback) {
                        Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                    }

                    Button(action: model.playNext) {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }

                    Button(action: model.cycleRepeatMode) {
                        Image(systemName: model.repeatMode == .one ? "repeat.1" : "repeat")
                            .font(.title2)
                            .foregroundStyle(model.repeatMode == .off ? .white : Color(red: 0.11, green: 0.73, blue: 0.33))
                    }
                }

                Spacer()
            }
            .padding()
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                }
            }
        }
    }

    private var currentTitle: String {
        if let url = model.savedFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return "Now Playing"
    }
}


private struct SpotifyImportView: View {
    @Bindable var model: PurerifyModel
    @Environment(\.dismiss) private var dismiss
    @State private var playlistURL = ""
    @State private var didStart = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    TextField("https://open.spotify.com/playlist/...", text: $playlistURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                    Button("Import") {
                        didStart = true
                        Task { await model.importSpotifyPlaylist(url: playlistURL) }
                    }
                    .disabled(playlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isImportingSpotify)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.11, green: 0.73, blue: 0.33), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.black)
                }
                .padding(.horizontal)

                if let name = model.spotifyImportName {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(.white)
                }

                if model.isImportingSpotify {
                    ProgressView(value: model.spotifyImportProgress)
                        .tint(Color(red: 0.11, green: 0.73, blue: 0.33))
                        .padding(.horizontal)
                }

                if let error = model.spotifyImportError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }

                List {
                    ForEach(model.spotifyImportTracks) { track in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            statusView(track.status)
                        }
                        .listRowBackground(Color.black)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .background(Color.black)
            .navigationTitle("Import from Spotify")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func statusView(_ status: SpotifyImportStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .matching:
            ProgressView().scaleEffect(0.7)
        case .downloading:
            ProgressView().scaleEffect(0.7)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
}
