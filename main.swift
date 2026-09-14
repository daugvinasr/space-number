import AppKit

let yabai = "/opt/homebrew/bin/yabai"
let skhd = "/opt/homebrew/bin/skhd"
// Per-user, like yabai's own socket, so instances on a shared machine don't
// collide. Must match the `nc -U` path in yabai/yabairc.
let socketPath = "/tmp/yabai-indicator_\(NSUserName()).socket"

struct Space: Decodable {
    let index: Int
    let hasFocus: Bool
    let isVisible: Bool
    let isNativeFullscreen: Bool
    let windows: [Int]

    enum CodingKeys: String, CodingKey {
        case index, windows
        case hasFocus = "has-focus"
        case isVisible = "is-visible"
        case isNativeFullscreen = "is-native-fullscreen"
    }
}

struct Window: Decodable {
    let id: Int
    let hasFullscreenZoom: Bool
    let isNativeFullscreen: Bool
    let isSticky: Bool
    let hasAXReference: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case hasFullscreenZoom = "has-fullscreen-zoom"
        case isNativeFullscreen = "is-native-fullscreen"
        case isSticky = "is-sticky"
        case hasAXReference = "has-ax-reference"
    }
}

// What actually gets drawn for one space; equality drives the redraw skip.
struct Cell: Equatable {
    let index: Int
    let focused: Bool
    let visible: Bool
    let fullscreen: Bool
}

let yabaiSocket = "/tmp/yabai_\(NSUserName()).socket"

// The yabai CLI is a thin client over the daemon's unix socket; talking to it
// directly skips a fork/exec per query. Wire format: 4-byte little-endian
// length prefix, then the argv NUL-separated with a trailing NUL. The reply is
// streamed until EOF; a first byte of 0x07 (BEL) marks an error message.
func yabaiMessage(_ args: [String]) -> Data? {
    guard let fd = connectUnix(yabaiSocket) else { return nil }
    defer { close(fd) }
    // A dying daemon mid-write must surface as an error, not SIGPIPE.
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var packet = Data()
    var payload = Data()
    for arg in args {
        payload.append(contentsOf: arg.utf8)
        payload.append(0)
    }
    payload.append(0)
    withUnsafeBytes(of: Int32(payload.count).littleEndian) { packet.append(contentsOf: $0) }
    packet.append(payload)

    var offset = 0
    while offset < packet.count {
        let n = packet.withUnsafeBytes {
            write(fd, $0.baseAddress! + offset, packet.count - offset)
        }
        if n > 0 { offset += n } else if errno == EINTR { continue } else { return nil }
    }

    var response = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n > 0 { response.append(buf, count: n) }
        else if n == 0 { break }
        else if errno == EINTR { continue }
        else { return nil }
    }
    if response.first == 0x07 {
        NSLog("space-number: yabai error: %@",
              String(data: response.dropFirst(), encoding: .utf8) ?? "?")
        return nil
    }
    return response
}

func yabaiQuery<T: Decodable>(_ args: String...) -> T? {
    guard let data = yabaiMessage(["query"] + args) else { return nil }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        // A schema drift (e.g. yabai renaming a field) must show up in the log,
        // not just as a silent "?" in the menu bar.
        NSLog("space-number: failed to decode `query %@`: %@",
              args.joined(separator: " "), "\(error)")
        return nil
    }
}

func sockaddrUn(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < maxPathLen else { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: maxPathLen) {
            _ = strcpy($0, path)
        }
    }
    return addr
}

// Runs a socket call (connect/bind) against the unix address for `path`,
// hiding the sockaddr_un -> sockaddr pointer dance. Returns success.
func withSockaddr(_ path: String, _ call: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Bool {
    guard var addr = sockaddrUn(path) else { return false }
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            call($0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
}

// A connected fd for the unix socket at `path`, or nil.
func connectUnix(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard withSockaddr(path, { connect(fd, $0, $1) }) else {
        close(fd)
        return nil
    }
    return fd
}

// A live instance answers connect() on its socket; a leftover file from a
// crashed one refuses, so it's safe to unlink and rebind.
func anotherInstanceIsRunning(at path: String) -> Bool {
    guard let fd = connectUnix(path) else { return false }
    close(fd)
    return true
}

// Listens on a unix socket; yabai signals poke it with `nc -U` to request a refresh.
final class RefreshSocket {
    private let acceptSource: DispatchSourceRead
    private let path: String

    init?(path: String, onMessage: @escaping () -> Void) {
        self.path = path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard withSockaddr(path, { bind(fd, $0, $1) }), listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        acceptSource.setEventHandler { [fd] in
            // The connection itself is the signal; don't read (a silent client
            // would block the main queue), just hang up.
            let client = accept(fd, nil, nil)
            if client >= 0 { close(client) }
            onMessage()
        }
        acceptSource.setCancelHandler { close(fd) }
        acceptSource.resume()
    }

    deinit {
        acceptSource.cancel()
        unlink(path)
    }
}

// Draws the menu bar image for a row of cells. Pure [Cell] -> NSImage, plus a
// glyph-measurement cache; knows nothing about yabai or the status item.
final class CellImageRenderer {
    private var symbolCache: [String: (image: NSImage, glyph: NSRect)] = [:]

    // SF Symbol images pad the glyph with margins (a "2.square" at pointSize 40
    // is a 46x41 image holding a 36x35 glyph). Naively aspect-fitting the image
    // shrinks the visible square and inflates the gaps, so measure the glyph's
    // actual alpha bounding box and scale by that instead.
    private func symbolInfo(_ name: String) -> (image: NSImage, glyph: NSRect)? {
        if let cached = symbolCache[name] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular)),
            let glyph = alphaBounds(of: image) else { return nil }
        symbolCache[name] = (image, glyph)
        return (image, glyph)
    }

    private func alphaBounds(of image: NSImage) -> NSRect? {
        let w = Int(ceil(image.size.width * 2)), h = Int(ceil(image.size.height * 2))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0 ..< h {
            for x in 0 ..< w where data[y * bpr + x * spp + 3] > 25 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        // bitmap rows are top-down; convert back to bottom-up point coords
        let fx = image.size.width / CGFloat(w), fy = image.size.height / CGFloat(h)
        return NSRect(x: CGFloat(minX) * fx,
                      y: CGFloat(h - 1 - maxY) * fy,
                      width: CGFloat(maxX - minX + 1) * fx,
                      height: CGFloat(maxY - minY + 1) * fy)
    }

    // i3-style ordered squares, after AeroSpace's MenuBarLabel (.i3Ordered).
    // Like AeroSpace, numeric workspaces use the SF Symbols "N.square.fill"
    // (focused) / "N.square"; spaces not currently visible are drawn dimmed,
    // and spaces holding a fullscreen window (native or yabai zoom-fullscreen)
    // get AeroSpace's dashed rounded border, with the glyph inset to make room.
    func image(for cells: [Cell]) -> NSImage {
        let itemSize: CGFloat = 20
        let spacing: CGFloat = 3

        let totalWidth = itemSize * CGFloat(cells.count)
            + spacing * CGFloat(max(0, cells.count - 1))
        let image = NSImage(size: NSSize(width: totalWidth, height: itemSize))
        image.lockFocus()
        var x: CGFloat = 0
        for cell in cells {
            var box = NSRect(x: x, y: 0, width: itemSize, height: itemSize)
            let alpha: CGFloat = cell.visible ? 1 : 0.5
            if cell.fullscreen {
                // Stroke straddles the path, so pull it half a linewidth inward
                // to keep it inside the box.
                let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                          xRadius: 2.5, yRadius: 2.5)
                border.lineWidth = 1
                border.setLineDash([4, 2], count: 2, phase: 1)
                NSColor.black.withAlphaComponent(alpha).setStroke()
                border.stroke()
                box = box.insetBy(dx: 3, dy: 3)
            }
            let symbolName = "\(cell.index).square" + (cell.focused ? ".fill" : "")
            if let (symbol, glyph) = symbolInfo(symbolName) {
                let scale = min(box.width / glyph.width, box.height / glyph.height)
                let drawRect = NSRect(x: box.midX - glyph.midX * scale,
                                      y: box.midY - glyph.midY * scale,
                                      width: symbol.size.width * scale,
                                      height: symbol.size.height * scale)
                symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: alpha)
            } else {
                // No SF Symbol beyond 50 — fall back to a plain number.
                let text = NSAttributedString(
                    string: String(cell.index),
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                        .foregroundColor: NSColor.black.withAlphaComponent(alpha),
                    ])
                let textSize = text.size()
                text.draw(at: NSPoint(x: box.midX - textSize.width / 2,
                                      y: box.midY - textSize.height / 2))
            }
            x += itemSize + spacing
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var refreshSocket: RefreshSocket?
    var pendingRefresh: DispatchWorkItem?
    var lastShown: [Cell]?
    let renderer = CellImageRenderer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        let about = NSMenuItem(title: "space-number \(appVersion) (\(appCommit))", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())
        let restart = NSMenuItem(title: "Restart yabai & skhd", action: #selector(restartServices), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)
        let stop = NSMenuItem(title: "Stop yabai & skhd", action: #selector(stopServices), keyEquivalent: "x")
        stop.target = self
        menu.addItem(stop)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        refreshSocket = RefreshSocket(path: socketPath) { [weak self] in
            self?.scheduleRefresh()
        }
        if refreshSocket == nil {
            NSLog("space-number: failed to listen on \(socketPath)")
        }

        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshSocket = nil  // deinit closes the fd and unlinks the socket file
    }

    @objc func restartServices() { runShell("\(yabai) --restart-service && \(skhd) --restart-service") }
    @objc func stopServices() { runShell("\(yabai) --stop-service && \(skhd) --stop-service") }

    func runShell(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", command]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch {
                NSLog("space-number: failed to run \(command): \(error)")
                return
            }
            task.waitUntilExit()
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }
    }

    // Coalesces bursts (e.g. window_moved firing on every frame of a drag) into one query.
    @objc func scheduleRefresh() {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    // Serial so overlapping refreshes can't render out of order.
    let queryQueue = DispatchQueue(label: "space-number.query", qos: .userInteractive)

    func refresh() {
        queryQueue.async {
            // Ask only for the fields we decode; the full --windows query also
            // marshals AX-backed fields (title etc.) with a much worse tail latency.
            let spaces: [Space]? = yabaiQuery(
                "--spaces", "index,has-focus,is-visible,is-native-fullscreen,windows")
            let windows: [Window]? = yabaiQuery(
                "--windows", "id,has-fullscreen-zoom,is-native-fullscreen,is-sticky,has-ax-reference")
            DispatchQueue.main.async { self.render(spaces, windows) }
        }
    }

    func render(_ spaces: [Space]?, _ windows: [Window]?) {
        guard let spaces = spaces else {
            statusItem.button?.image = nil
            statusItem.button?.title = "?"
            lastShown = nil
            return
        }

        let fullscreenWindows = Set((windows ?? [])
            .filter { $0.hasFullscreenZoom || $0.isNativeFullscreen }
            .map(\.id))
        // Windows that don't count toward a space being "occupied":
        // - sticky ones (e.g. CleanShot X's overlay) belong to every space;
        // - ones without an AX reference are ghosts: Electron apps like
        //   Bitwarden "close to tray" by ordering the window out rather than
        //   destroying it, and macOS keeps it assigned to its space.
        let ignoredWindows = Set((windows ?? [])
            .filter { $0.isSticky || !$0.hasAXReference }
            .map(\.id))
        let shown = spaces.filter {
            !$0.windows.allSatisfy(ignoredWindows.contains) || $0.isVisible
        }
            .map {
                Cell(index: $0.index, focused: $0.hasFocus, visible: $0.isVisible,
                     fullscreen: $0.isNativeFullscreen
                         || $0.windows.contains(where: fullscreenWindows.contains))
            }

        // Skip re-rendering (and menu bar redraw) when nothing changed.
        if shown == lastShown { return }
        lastShown = shown

        statusItem.button?.title = ""
        statusItem.button?.image = renderer.image(for: shown)
    }
}

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-v" }) {
    print("space-number \(appVersion) (\(appCommit))")
    exit(0)
}

if anotherInstanceIsRunning(at: socketPath) {
    NSLog("space-number: another instance is already running; exiting")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
