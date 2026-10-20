// BrowserCast — a window-only remote view + control page for BrowserOS,
// served from Suresh's Mac mini over his Tailscale network.
//
// Design (single control window = the Muse chat):
//   * The agent stages a login page in BrowserOS (via the BrowserOS MCP lane),
//     then drops the cast link in chat.
//   * Suresh opens the link on his phone: he sees ONLY the BrowserOS window
//     (ScreenCaptureKit single-window capture, MJPEG stream) and can tap to
//     click and type text that is relayed into that window as keystrokes.
//   * He types his own password himself — no credential ever passes through
//     the agent, the chat, or any store. Nothing is recorded or saved.
//   * Access is gated by a random token in the link; the server binds to the
//     Mac's Tailscale IP only. Never expose it beyond the tailnet.
//
// v1.1: text is typed via Unicode-string key events (layout/modifier-proof —
// v1.0's raw keycode + synthetic Shift path mangled capitals and digits).
// Server reads full request bodies (Content-Length), the page shows server
// responses instead of failing silently, and /status reports permission state.
// v1.0 scope: one stream client, click + double-click, text typing, a few
// special keys. No scroll relay yet (login pages fit on one screen).

import AppKit
import Foundation
import Security
import Network
import ScreenCaptureKit
import CoreImage

// MARK: - Constants

let kCastPort: UInt16 = 9021
let kTargetAppName = "BrowserOS"   // window owner to capture

// MARK: - Helpers

func appSupportDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("BrowserCast", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func logLine(_ s: String) { print("[BrowserCast] \(s)"); fflush(stdout) }

func loadOrCreateToken() -> String {
    let url = appSupportDir().appendingPathComponent("token.txt")
    if let t = try? String(contentsOf: url, encoding: .utf8) {
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 16 { return trimmed }
    }
    var bytes = [UInt8](repeating: 0, count: 24)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    try? token.write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return token
}

func discoverTailnetIP() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
        defer { ptr = p.pointee.ifa_next }
        guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = sockaddr_in()
        memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
        var inaddr = sin.sin_addr
        inet_ntop(AF_INET, &inaddr, &ip, socklen_t(INET_ADDRSTRLEN))
        let s = String(cString: ip)
        let parts = s.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return s }
    }
    return nil
}

// MARK: - Typing
//
// Text is typed with Unicode-string key events: each event carries the exact
// character, so the receiving app never has to translate keycode + modifier
// state (the v1.0 raw-keycode path mangled capitals, digits, and symbols).
// Special keys (Tab/Enter/Esc/…) still use their real keycodes — those are
// layout-independent.

func postKey(code: UInt16, shift: Bool) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false)
    if shift { down?.flags = .maskShift; up?.flags = .maskShift }
    down?.post(tap: .cghidEventTap)
    usleep(2000)
    up?.post(tap: .cghidEventTap)
}

func typeText(_ s: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in s {
        let units = Array(String(ch).utf16)
        guard !units.isEmpty else { continue }
        for keyDown in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: keyDown) else { continue }
            units.withUnsafeBufferPointer { buf in
                CGEventKeyboardSetUnicodeString(ev, stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            ev.post(tap: .cghidEventTap)
            usleep(2000)
        }
        usleep(12000)
    }
}

func postClick(at point: CGPoint, double: Bool) {
    let src = CGEventSource(stateID: .hidSystemState)
    let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
    move?.post(tap: .cghidEventTap)
    usleep(40_000)
    for _ in 0..<(double ? 2 : 1) {
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        if double { down?.setIntegerValueField(.mouseEventClickState, value: 2); up?.setIntegerValueField(.mouseEventClickState, value: 2) }
        down?.post(tap: .cghidEventTap)
        usleep(60_000)
        up?.post(tap: .cghidEventTap)
        usleep(80_000)
    }
}

// MARK: - Window capture (ScreenCaptureKit, single window)

class CastStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var window: SCWindow?
    private var stream: SCStream?
    private(set) var running = false
    private var lastFrameAt: Date = .distantPast
    var onFrame: ((Data) -> Void)?
    private let ciContext = CIContext()

    func findWindow() async -> SCWindow? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let candidates = content.windows.filter {
                $0.owningApplication?.applicationName == kTargetAppName &&
                $0.frame.width > 200 && $0.frame.height > 200
            }
            return candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        } catch {
            logLine("shareable content error: \(error)")
            return nil
        }
    }

    func ensureRunning() {
        if running { return }
        Task {
            guard let win = await findWindow() else {
                logLine("no \(kTargetAppName) window found")
                return
            }
            window = win
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let config = SCStreamConfiguration()
            config.width = Int(win.frame.width)
            config.height = Int(win.frame.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 8) // ~8 fps max
            config.queueDepth = 5
            config.showsCursor = true
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cast.frames"))
                try await s.startCapture()
                stream = s
                running = true
                logLine("capture started: \(win.title ?? "?") \(Int(win.frame.width))x\(Int(win.frame.height))")
            } catch {
                logLine("startCapture failed: \(error)")
            }
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        running = false
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFrameAt) >= 0.12 else { return }
        lastFrameAt = now
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pixel)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.62]) else { return }
        onFrame?(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logLine("stream stopped with error: \(error)")
        running = false
        self.stream = nil
    }
}

// MARK: - HTTP server (page / MJPEG stream / input / status)

class StreamClient {
    let conn: NWConnection
    var sending = false
    var pending: Data?
    init(_ conn: NWConnection) { self.conn = conn }
}

class CastServer {
    let token: String
    let streamer = CastStreamer()
    var listener: NWListener?
    private var clients: [ObjectIdentifier: StreamClient] = [:]
    private let lock = NSLock()

    init(token: String) {
        self.token = token
        streamer.onFrame = { [weak self] jpeg in self?.fanout(jpeg) }
    }

    func start() {
        let params = NWParameters.tcp
        if let ip = discoverTailnetIP(), let addr = IPv4Address(ip) {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(addr), port: .init(rawValue: kCastPort)!)
            logLine("binding cast server to tailnet \(ip):\(kCastPort)")
        } else {
            logLine("WARNING: no tailnet IP — binding on all interfaces (token still required)")
        }
        do { listener = try NWListener(using: params, on: .init(rawValue: kCastPort)!) }
        catch { logLine("listener failed: \(error)"); return }
        listener?.stateUpdateHandler = { logLine("listener state: \($0)") }
        listener?.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    // MARK: frame fanout
    func fanout(_ jpeg: Data) {
        var frame = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        frame.append(jpeg)
        frame.append(Data("\r\n".utf8))
        lock.lock()
        let current = Array(clients.values)
        lock.unlock()
        for client in current { sendFrame(client, frame) }
    }

    func sendFrame(_ client: StreamClient, _ data: Data) {
        lock.lock()
        if client.sending { client.pending = data; lock.unlock(); return }
        client.sending = true
        lock.unlock()
        client.conn.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            client.sending = false
            let next = client.pending
            client.pending = nil
            self.lock.unlock()
            if let next = next { self.sendFrame(client, next) }
        })
    }

    // MARK: request handling
    func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.removeClient(conn) }
            if case .failed = state { self?.removeClient(conn) }
        }
        conn.start(queue: .global(qos: .userInitiated))
        readRequest(conn, buffer: Data())
    }

    /// Accumulate until the request is complete (headers + full Content-Length
    /// body) before dispatching — a single receive() can return only the
    /// headers when a phone browser sends the body in a separate packet.
    func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self = self else { conn.cancel(); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            guard let raw = String(data: buf, encoding: .utf8),
                  let sepRange = raw.range(of: "\r\n\r\n") else {
                if isComplete || buf.count > 65536 { conn.cancel(); return }
                self.readRequest(conn, buffer: buf)
                return
            }
            let headPart = String(raw[raw.startIndex..<sepRange.lowerBound])
            var contentLength = 0
            for line in headPart.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            let bodyAvailable = buf.count - (headPart.utf8.count + 4)
            if bodyAvailable < contentLength {
                if isComplete { conn.cancel(); return }
                self.readRequest(conn, buffer: buf)
                return
            }
            self.dispatch(conn, raw: raw)
        }
    }

    func dispatch(_ conn: NWConnection, raw: String) {
        do {
            let head = raw.components(separatedBy: "\r\n\r\n").first ?? ""
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first ?? ""
            let parts = requestLine.split(separator: " ")
            let method = parts.count > 0 ? String(parts[0]) : ""
            let target = parts.count > 1 ? String(parts[1]) : "/"
            let bodyStr = raw.components(separatedBy: "\r\n\r\n").count > 1 ? raw.components(separatedBy: "\r\n\r\n")[1] : ""

            // token from ?t= query
            var queryToken = ""
            if let q = target.split(separator: "?").dropFirst().first {
                for pair in q.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2, kv[0] == "t" { queryToken = String(kv[1]) }
                }
            }
            let path = String(target.split(separator: "?").first ?? "/")
            guard queryToken == self.token else {
                self.respond(conn, status: 401, type: "text/plain", body: Data("bad token".utf8), close: true)
                return
            }

            switch (method, path) {
            case ("GET", "/"), ("GET", "/cast"):
                self.respond(conn, status: 200, type: "text/html; charset=utf-8", body: Data(castPageHTML(token: self.token).utf8), close: true)
            case ("GET", "/stream"):
                self.lock.lock()
                if self.clients.count >= 1 {
                    self.lock.unlock()
                    self.respond(conn, status: 409, type: "text/plain", body: Data("a cast client is already connected".utf8), close: true)
                    return
                }
                let client = StreamClient(conn)
                self.clients[ObjectIdentifier(conn)] = client
                self.lock.unlock()
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
                self.streamer.ensureRunning()
            case ("GET", "/status"):
                Task {
                    let win = await self.streamer.findWindow()
                    let info: [String: Any] = [
                        "ok": true,
                        "version": "1.1",
                        "windowFound": win != nil,
                        "windowTitle": win?.title ?? "",
                        "streaming": self.streamer.running,
                        "clients": self.clients.count,
                        "accessibilityTrusted": AXIsProcessTrusted(),
                        "screenCaptureOk": CGPreflightScreenCaptureAccess(),
                    ]
                    let body = (try? JSONSerialization.data(withJSONObject: info)) ?? Data()
                    self.respond(conn, status: 200, type: "application/json", body: body, close: true)
                }
            case ("POST", "/input"):
                self.handleInput(conn, body: bodyStr)
            default:
                self.respond(conn, status: 404, type: "text/plain", body: Data("not found".utf8), close: true)
            }
        }
    }

    func removeClient(_ conn: NWConnection) {
        lock.lock()
        clients.removeValue(forKey: ObjectIdentifier(conn))
        let empty = clients.isEmpty
        lock.unlock()
        if empty { streamer.stop(); logLine("last client gone — capture stopped") }
    }

    func respond(_ conn: NWConnection, status: Int, type: String, body: Data, close: Bool) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in if close { conn.cancel() } })
    }

    func handleInput(_ conn: NWConnection, body: String) {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["kind"] as? String else {
            logLine("input rejected: unparseable body (\(body.count) bytes)")
            respond(conn, status: 400, type: "text/plain", body: Data("bad input".utf8), close: true)
            return
        }
        // Log kind/length only — never the content (it may be a password).
        let textLen = (obj["text"] as? String)?.count ?? 0
        logLine("input: kind=\(kind)\(kind == "text" ? " chars=\(textLen)" : "") axTrusted=\(AXIsProcessTrusted())")
        Task {
            // Target the captured window's app
            let win = self.streamer.window ?? (await self.streamer.findWindow())
            guard let win = win else {
                self.respond(conn, status: 409, type: "text/plain", body: Data("no \(kTargetAppName) window".utf8), close: true)
                return
            }
            if let pid = win.owningApplication?.processID {
                NSRunningApplication(processIdentifier: pid)?.activate()
                usleep(120_000)
            }
            switch kind {
            case "click":
                let nx = (obj["nx"] as? Double) ?? 0.5
                let ny = (obj["ny"] as? Double) ?? 0.5
                let dbl = (obj["double"] as? Bool) ?? false
                let point = CGPoint(x: win.frame.origin.x + CGFloat(nx) * win.frame.width,
                                    y: win.frame.origin.y + CGFloat(ny) * win.frame.height)
                postClick(at: point, double: dbl)
                self.respond(conn, status: 200, type: "text/plain", body: Data("clicked".utf8), close: true)
            case "text":
                let text = (obj["text"] as? String) ?? ""
                typeText(text)
                self.respond(conn, status: 200, type: "text/plain", body: Data("typed \(text.count) chars".utf8), close: true)
            case "key":
                let key = (obj["key"] as? String) ?? ""
                let codes: [String: UInt16] = ["tab": 48, "enter": 36, "esc": 53, "backspace": 51, "space": 49, "delete": 117]
                if let code = codes[key] { postKey(code: code, shift: false) }
                self.respond(conn, status: 200, type: "text/plain", body: Data("key sent".utf8), close: true)
            default:
                self.respond(conn, status: 400, type: "text/plain", body: Data("unknown kind".utf8), close: true)
            }
        }
    }
}

// MARK: - The cast page

func castPageHTML(token: String) -> String {
    return """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <title>BrowserCast — BrowserOS</title>
    <style>
      body{margin:0;background:#111;color:#eee;font-family:-apple-system,system-ui,sans-serif}
      #wrap{max-width:1100px;margin:0 auto;padding:8px}
      img#view{width:100%;border:1px solid #333;border-radius:6px;background:#000;touch-action:manipulation}
      .row{display:flex;gap:6px;margin-top:8px;flex-wrap:wrap}
      input[type=password],input[type=text]{flex:1;min-width:140px;padding:10px;font-size:16px;border-radius:6px;border:1px solid #444;background:#1c1c1e;color:#fff}
      button{padding:10px 14px;font-size:15px;border-radius:6px;border:1px solid #444;background:#2c2c2e;color:#fff}
      button:active{background:#444}
      .hint{color:#999;font-size:12px;margin-top:6px;line-height:1.5}
    </style></head><body><div id="wrap">
    <img id="view" src="/stream?t=\(token)" alt="BrowserOS window">
    <div class="row">
      <input id="txt" type="text" placeholder="Type here, then tap 'Type into Mac' (use the password box below for passwords)" autocomplete="off">
      <button onclick="sendText('txt')">Type into Mac</button>
    </div>
    <div class="row">
      <input id="pwd" type="password" placeholder="Password (masked here, typed into the Mac)" autocomplete="off">
      <button onclick="sendText('pwd')">Type password</button>
    </div>
    <div class="row">
      <button onclick="sendKey('tab')">Tab</button>
      <button onclick="sendKey('enter')">Enter</button>
      <button onclick="sendKey('backspace')">⌫</button>
      <button onclick="sendKey('esc')">Esc</button>
    </div>
    <div id="status" class="hint">Ready.</div>
    <div class="hint">Tap the image to click there (e.g. tap the username field, then type above; tap the password field, then use the password box). Double-tap = double click. What you type is sent only to your Mac over your Tailscale network and typed into the window — it is never stored.</div>
    </div>
    <script>
      const T = "\(token)";
      const img = document.getElementById('view');
      const statusEl = document.getElementById('status');
      let lastTap = 0;
      function setStatus(s){ statusEl.textContent = s; }
      async function post(body){
        setStatus('Sending…');
        try {
          const r = await fetch('/input?t='+T, {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)});
          const t = await r.text();
          setStatus(r.ok ? ('✓ Mac: ' + t) : ('✗ Mac error ' + r.status + ': ' + t));
          return r.ok;
        } catch(err) {
          setStatus('✗ Could not reach the Mac: ' + err);
          return false;
        }
      }
      img.addEventListener('click', e => {
        const r = img.getBoundingClientRect();
        const nx = (e.clientX - r.left)/r.width, ny = (e.clientY - r.top)/r.height;
        const now = Date.now(); const dbl = (now - lastTap) < 350; lastTap = now;
        post({kind:'click', nx:nx, ny:ny, double:dbl});
      });
      async function sendText(id){
        const el = document.getElementById(id);
        if(!el.value){ setStatus('Nothing to send — the box is empty.'); return; }
        const ok = await post({kind:'text', text: el.value});
        if(ok){ el.value=''; }
        el.focus();
      }
      function sendKey(k){ post({kind:'key', key:k}); }
      document.getElementById('txt').addEventListener('keydown', e => { if(e.key === 'Enter'){ e.preventDefault(); sendText('txt'); } });
      document.getElementById('pwd').addEventListener('keydown', e => { if(e.key === 'Enter'){ e.preventDefault(); sendText('pwd'); } });
    </script></body></html>
    """
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var server: CastServer?
    let token = loadOrCreateToken()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: "BrowserCast")
            button.title = " Cast"
        }
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy Cast Link", action: #selector(copyLink), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let copyTok = NSMenuItem(title: "Copy Token (for Muse)", action: #selector(copyToken), keyEquivalent: "")
        copyTok.target = self
        menu.addItem(copyTok)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit BrowserCast", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        // One-time permission prompts, surfaced at install/first run:
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }

        server = CastServer(token: token)
        server?.start()
        let ip = discoverTailnetIP() ?? "<no-tailnet-ip>"
        logLine("BrowserCast up: http://\(ip):\(kCastPort)/?t=\(token)")
    }

    @objc func copyLink() {
        let ip = discoverTailnetIP() ?? "100.74.58.102"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://\(ip):\(kCastPort)/?t=\(token)", forType: .string)
    }

    @objc func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
