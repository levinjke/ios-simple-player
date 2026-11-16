import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import MediaPlayer

enum RepeatMode: String, Codable, CaseIterable {
    case off
    case all
    case one
}

struct Track: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let fileName: String
}

struct Playlist: Identifiable, Codable {
    let id: UUID
    var name: String
    var tracks: [Track]
}

class AudioManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playlists: [Playlist] = []
    @Published var currentPlaylistID: UUID?
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var isMuted = false
    @Published var volume: Float = 0.8 {
        didSet {
            if volume > 0 && isMuted {
                isMuted = false
            }
            if !isMuted {
                previousVolume = volume
            }
            audioPlayer?.volume = isMuted ? 0 : volume
        }
    }
    
    private var previousVolume: Float = 0.8
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private let saveKey = "SavedPlaylistsData"
    
    override init() {
        super.init()
        setupAudioSession()
        setupRemoteTransportControls()
        loadPlaylists()
        
        if playlists.isEmpty {
            let defaultPlaylist = Playlist(id: UUID(), name: "Моя музыка", tracks: [])
            playlists.append(defaultPlaylist)
            savePlaylists()
        }
        currentPlaylistID = playlists.first?.id
        startTimer()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Ошибка аудиосессии: \(error.localizedDescription)")
        }
    }
    
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self, !self.isPlaying else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.isPlaying else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextTrack()
            return .success
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousTrack()
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: positionEvent.positionTime)
            return .success
        }
    }
    
    private func updateNowPlayingInfo() {
        guard let track = currentTrack, let player = audioPlayer else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        let playlistName = playlists.first(where: { $0.id == currentPlaylistID })?.name ?? "Плейлист"
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = playlistName
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = player.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func importTracks(urls: [URL], to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        
        for url in urls {
            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            let fileExtension = url.pathExtension
            let uniqueFileName = "\(UUID().uuidString).\(fileExtension)"
            let destinationURL = getDocumentsDirectory().appendingPathComponent(uniqueFileName)
            
            do {
                try FileManager.default.copyItem(at: url, to: destinationURL)
                let title = url.deletingPathExtension().lastPathComponent
                let newTrack = Track(id: UUID(), title: title, fileName: uniqueFileName)
                playlists[index].tracks.append(newTrack)
            } catch {
                print("Ошибка копирования файла: \(error.localizedDescription)")
            }
        }
        savePlaylists()
    }
    
    func createPlaylist(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newPlaylist = Playlist(id: UUID(), name: trimmed, tracks: [])
        playlists.append(newPlaylist)
        savePlaylists()
    }
    
    func deletePlaylist(at offsets: IndexSet) {
        for index in offsets {
            let playlist = playlists[index]
            for track in playlist.tracks {
                removeFile(fileName: track.fileName)
                if currentTrack?.id == track.id {
                    stopPlayback()
                }
            }
        }
        playlists.remove(atOffsets: offsets)
        savePlaylists()
    }
    
    func deleteTrack(at offsets: IndexSet, from playlistID: UUID) {
        guard let pIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for index in offsets {
            let track = playlists[pIndex].tracks[index]
            removeFile(fileName: track.fileName)
            if currentTrack?.id == track.id {
                stopPlayback()
            }
        }
        playlists[pIndex].tracks.remove(atOffsets: offsets)
        savePlaylists()
    }
    
    private func removeFile(fileName: String) {
        let fileURL = getDocumentsDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    func playTrack(_ track: Track, in playlistID: UUID) {
        let fileURL = getDocumentsDirectory().appendingPathComponent(track.fileName)
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            audioPlayer?.delegate = self
            audioPlayer?.volume = isMuted ? 0 : volume
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            currentTrack = track
            currentPlaylistID = playlistID
            duration = audioPlayer?.duration ?? 0
            currentTime = 0
            isPlaying = true
            
            updateNowPlayingInfo()
        } catch {
            print("Ошибка воспроизведения: \(error.localizedDescription)")
        }
    }
    
    func togglePlayPause() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlayingInfo()
    }
    
    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            if volume > 0 {
                previousVolume = volume
            }
            audioPlayer?.volume = 0
        } else {
            if volume == 0 {
                volume = previousVolume > 0 ? previousVolume : 0.5
            }
            audioPlayer?.volume = volume
        }
    }
    
    func toggleShuffle() {
        isShuffled.toggle()
    }
    
    func toggleRepeat() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
    }
    
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        currentTrack = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        updateNowPlayingInfo()
    }
    
    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        let clampedTime = min(max(0, time), player.duration)
        player.currentTime = clampedTime
        currentTime = clampedTime
        updateNowPlayingInfo()
    }
    
    func nextTrack(autoTriggered: Bool = false) {
        guard let pID = currentPlaylistID,
              let playlist = playlists.first(where: { $0.id == pID }),
              !playlist.tracks.isEmpty,
              let current = currentTrack,
              let index = playlist.tracks.firstIndex(of: current) else { return }
        
        if autoTriggered && repeatMode == .one {
            seek(to: 0)
            audioPlayer?.play()
            isPlaying = true
            updateNowPlayingInfo()
            return
        }
        
        if isShuffled {
            if playlist.tracks.count == 1 {
                seek(to: 0)
                audioPlayer?.play()
                isPlaying = true
                updateNowPlayingInfo()
            } else {
                var randomIndex = Int.random(in: 0..<playlist.tracks.count)
                while randomIndex == index {
                    randomIndex = Int.random(in: 0..<playlist.tracks.count)
                }
                playTrack(playlist.tracks[randomIndex], in: pID)
            }
            return
        }
        
        if autoTriggered && repeatMode == .off && index == playlist.tracks.count - 1 {
            seek(to: 0)
            audioPlayer?.pause()
            isPlaying = false
            updateNowPlayingInfo()
            return
        }
        
        let nextIndex = (index + 1) % playlist.tracks.count
        playTrack(playlist.tracks[nextIndex], in: pID)
    }
    
    func previousTrack() {
        guard let pID = currentPlaylistID,
              let playlist = playlists.first(where: { $0.id == pID }),
              !playlist.tracks.isEmpty,
              let current = currentTrack,
              let index = playlist.tracks.firstIndex(of: current) else { return }
        
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        
        if isShuffled && playlist.tracks.count > 1 {
            var randomIndex = Int.random(in: 0..<playlist.tracks.count)
            while randomIndex == index {
                randomIndex = Int.random(in: 0..<playlist.tracks.count)
            }
            playTrack(playlist.tracks[randomIndex], in: pID)
            return
        }
        
        let prevIndex = (index - 1 + playlist.tracks.count) % playlist.tracks.count
        playTrack(playlist.tracks[prevIndex], in: pID)
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            nextTrack(autoTriggered: true)
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.currentTime = player.currentTime
            self.isPlaying = player.isPlaying
        }
    }
    
    private func savePlaylists() {
        if let encoded = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
        }
    }
    
    private func loadPlaylists() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = decoded
        }
    }
}

struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var showFullPlayer = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    ForEach(audioManager.playlists) { playlist in
                        NavigationLink(destination: PlaylistDetailView(playlistID: playlist.id, audioManager: audioManager)) {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .foregroundColor(.blue)
                                    .font(.title2)
                                    .frame(width: 36)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.name)
                                        .font(.headline)
                                    Text("Треков: \(playlist.tracks.count)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete(perform: audioManager.deletePlaylist)
                }
                .listStyle(.insetGrouped)
                
                if let currentTrack = audioManager.currentTrack {
                    MiniPlayerView(audioManager: audioManager, track: currentTrack)
                        .onTapGesture {
                            showFullPlayer = true
                        }
                }
            }
            .navigationTitle("Плейлисты")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showNewPlaylistAlert = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Новый плейлист", isPresented: $showNewPlaylistAlert) {
                TextField("Название плейлиста", text: $newPlaylistName)
                Button("Создать") {
                    audioManager.createPlaylist(name: newPlaylistName)
                    newPlaylistName = ""
                }
                Button("Отмена", role: .cancel) {
                    newPlaylistName = ""
                }
            }
            .sheet(isPresented: $showFullPlayer) {
                FullPlayerView(audioManager: audioManager)
            }
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID
    @ObservedObject var audioManager: AudioManager
    @State private var showFileImporter = false
    
    private var playlist: Playlist? {
        audioManager.playlists.first(where: { $0.id == playlistID })
    }
    
    var body: some View {
        VStack {
            if let playlist = playlist {
                if playlist.tracks.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("В этом плейлисте пока нет треков")
                            .foregroundColor(.secondary)
                        Button("Добавить из Файлов") {
                            showFileImporter = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(playlist.tracks) { track in
                            Button(action: {
                                audioManager.playTrack(track, in: playlist.id)
                            }) {
                                HStack {
                                    Image(systemName: audioManager.currentTrack?.id == track.id && audioManager.isPlaying ? "speaker.wave.2.fill" : "music.note")
                                        .foregroundColor(audioManager.currentTrack?.id == track.id ? .blue : .secondary)
                                    
                                    Text(track.title)
                                        .foregroundColor(audioManager.currentTrack?.id == track.id ? .blue : .primary)
                                        .fontWeight(audioManager.currentTrack?.id == track.id ? .semibold : .regular)
                                        .lineLimit(1)
                                    
                                    Spacer()
                                }
                            }
                        }
                        .onDelete { offsets in
                            audioManager.deleteTrack(at: offsets, from: playlist.id)
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .navigationTitle(playlist?.name ?? "Плейлист")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showFileImporter = true }) {
                    Image(systemName: "plus.circle.fill")
                    Text("Добавить")
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                audioManager.importTracks(urls: urls, to: playlistID)
            }
        }
    }
}

struct MiniPlayerView: View {
    @ObservedObject var audioManager: AudioManager
    let track: Track
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .padding(8)
                    .background(Color.blue.opacity(0.15))
                    .cornerRadius(8)
                    .foregroundColor(.blue)
                
                Text(track.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                Spacer()
                
                Button(action: audioManager.previousTrack) {
                    Image(systemName: "backward.fill")
                        .font(.body)
                        .foregroundColor(.primary)
                }
                
                Button(action: audioManager.togglePlayPause) {
                    Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundColor(.primary)
                        .frame(width: 24)
                }
                
                Button(action: { audioManager.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemBackground))
        }
    }
}

struct FullPlayerView: View {
    @ObservedObject var audioManager: AudioManager
    @State private var isDraggingTime = false
    @State private var tempTime: TimeInterval = 0
    
    private var repeatIconName: String {
        switch audioManager.repeatMode {
        case .off, .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }
    
    var body: some View {
        VStack(spacing: 32) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 12)
            
            Spacer()
            
            Text(audioManager.currentTrack?.title ?? "Нет трека")
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 24)
            
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { isDraggingTime ? tempTime : audioManager.currentTime },
                        set: { newValue in
                            tempTime = newValue
                        }
                    ),
                    in: 0...max(audioManager.duration, 0.1),
                    onEditingChanged: { editing in
                        isDraggingTime = editing
                        if !editing {
                            audioManager.seek(to: tempTime)
                        }
                    }
                )
                
                HStack {
                    Text(formatTime(isDraggingTime ? tempTime : audioManager.currentTime))
                    Spacer()
                    Text(formatTime(audioManager.duration))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 30)
            
            // Основные кнопки управления: Shuffle, Назад, Пауза/Пуск, Вперед, Repeat
            HStack(spacing: 28) {
                Button(action: audioManager.toggleShuffle) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(audioManager.isShuffled ? .blue : .secondary)
                        .padding(8)
                        .background(audioManager.isShuffled ? Color.blue.opacity(0.15) : Color.clear)
                        .clipShape(Circle())
                }
                
                Button(action: audioManager.previousTrack) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.primary)
                }
                
                Button(action: audioManager.togglePlayPause) {
                    Image(systemName: audioManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 66))
                        .foregroundColor(.primary)
                }
                
                Button(action: { audioManager.nextTrack() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.primary)
                }
                
                Button(action: audioManager.toggleRepeat) {
                    Image(systemName: repeatIconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(audioManager.repeatMode != .off ? .blue : .secondary)
                        .padding(8)
                        .background(audioManager.repeatMode != .off ? Color.blue.opacity(0.15) : Color.clear)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            
            // Громкость и кнопка Mute
            HStack(spacing: 14) {
                Button(action: audioManager.toggleMute) {
                    Image(systemName: audioManager.isMuted || audioManager.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 18))
                        .foregroundColor(audioManager.isMuted || audioManager.volume == 0 ? .red : .secondary)
                        .frame(width: 28)
                }
                
                Slider(
                    value: Binding(
                        get: { audioManager.isMuted ? 0 : audioManager.volume },
                        set: { newValue in
                            audioManager.volume = newValue
                        }
                    ),
                    in: 0...1
                )
                .accentColor(audioManager.isMuted ? .red : .gray)
                
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 30)
            
            Spacer()
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
