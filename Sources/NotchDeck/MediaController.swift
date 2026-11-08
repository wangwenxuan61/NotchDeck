import AppKit

/// 普通 App 读不到系统“正在播放”信息，这里借助系统自带的 osascript 读取；
/// 脚本循环一段时间后自动退出再重启，防止长期运行积累内存，App 崩溃时也不会留下常驻进程。
final class MediaController: ObservableObject {
    static let shared = MediaController()

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var album = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var sourceName = ""
    @Published private(set) var sourceIcon: NSImage?

    private var elapsed: Double = 0
    private var timestamp: Double = 0
    private var rate: Double = 0
    private var sourceBundle = ""

    private var process: Process?
    private var buffer = Data()
    private var stopped = false

    private static let script = """
    ObjC.import('Foundation');
    $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
    var R = $.NSClassFromString('MRNowPlayingRequest');
    function text(info, key) {
      var value = info.objectForKey($('kMRMediaRemoteNowPlayingInfo' + key));
      return value.isNil() ? '' : ObjC.unwrap(value);
    }
    function number(info, key) {
      var value = info.objectForKey($('kMRMediaRemoteNowPlayingInfo' + key));
      return value.isNil() ? 0 : value.doubleValue;
    }
    var lastArt = null;
    for (var n = 0; n < 400; n++) {
      var out = {title: '', artist: '', album: '', playing: false, duration: 0, elapsed: 0, timestamp: 0, rate: 0, bundle: '', source: ''};
      try {
        var item = R.localNowPlayingItem;
        if (!item.isNil() && !item.nowPlayingInfo.isNil()) {
          var info = item.nowPlayingInfo;
          out.title = text(info, 'Title');
          out.artist = text(info, 'Artist');
          out.album = text(info, 'Album');
          out.duration = number(info, 'Duration');
          out.elapsed = number(info, 'ElapsedTime');
          out.rate = number(info, 'PlaybackRate');
          var stamp = info.objectForKey($('kMRMediaRemoteNowPlayingInfoTimestamp'));
          out.timestamp = stamp.isNil() ? 0 : stamp.timeIntervalSince1970;
          var art = info.objectForKey($('kMRMediaRemoteNowPlayingInfoArtworkData'));
          var artKey = art.isNil() ? '' : out.title + '|' + art.length;
          if (artKey !== lastArt) {
            lastArt = artKey;
            out.artwork = art.isNil() ? '' : ObjC.unwrap(art.base64EncodedStringWithOptions(0));
          }
        }
        out.playing = R.localIsPlaying === true;
      } catch (e) {}
      try {
        var client = R.localNowPlayingPlayerPath.client;
        out.bundle = ObjC.unwrap(client.bundleIdentifier) || '';
        out.source = ObjC.unwrap(client.displayName) || '';
      } catch (e) {}
      console.log(JSON.stringify(out));
      delay(1.5);
    }
    """

    private struct Payload: Decodable {
        let title: String
        let artist: String
        let album: String
        let playing: Bool
        let duration: Double
        let elapsed: Double
        let timestamp: Double
        let rate: Double
        let bundle: String
        let source: String
        /// 没有这个字段表示封面没变，空字符串表示封面已清除。
        let artwork: String?
    }

    func start() { launch() }

    func stop() {
        stopped = true
        process?.terminate()
    }

    private func launch() {
        guard !stopped else { return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", Self.script]
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.launch() }
        }
        guard (try? process.run()) != nil else { return }
        self.process = process
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(line)) else { continue }
            if payload.title != title { title = payload.title }
            if payload.artist != artist { artist = payload.artist }
            if payload.playing != isPlaying { isPlaying = payload.playing }
            if payload.album != album { album = payload.album }
            if payload.duration != duration { duration = payload.duration }
            elapsed = payload.elapsed
            timestamp = payload.timestamp
            rate = payload.rate
            if let encoded = payload.artwork {
                artwork = Data(base64Encoded: encoded).flatMap { NSImage(data: $0) }
            }
            if payload.source != sourceName { sourceName = payload.source }
            if payload.bundle != sourceBundle {
                sourceBundle = payload.bundle
                sourceIcon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: payload.bundle)
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
            }
        }
    }

    /// 脚本每 1.5 秒才上报一次，界面上的进度用时间戳和播放速率推算。
    func position(at date: Date) -> Double {
        guard isPlaying, timestamp > 0 else { return elapsed }
        let advanced = elapsed + (date.timeIntervalSince1970 - timestamp) * max(rate, 1)
        return duration > 0 ? min(advanced, duration) : advanced
    }

    private typealias SetElapsedTime = @convention(c) (Double) -> Void
    private static let setElapsedTime: SetElapsedTime? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSetElapsedTime") else { return nil }
        return unsafeBitCast(symbol, to: SetElapsedTime.self)
    }()

    func seek(to seconds: Double) {
        Self.setElapsedTime?(seconds)
        elapsed = seconds
        timestamp = Date().timeIntervalSince1970
    }

    private enum Command: UInt32 { case toggle = 2, next = 4, previous = 5 }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let sendCommand: SendCommand? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    private func send(_ command: Command) { _ = Self.sendCommand?(command.rawValue, nil) }

    func togglePlayPause() {
        send(.toggle)
        isPlaying.toggle()
    }

    func next() { send(.next) }
    func previous() { send(.previous) }
}
