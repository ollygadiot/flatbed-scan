// ScanButton: turns the Epson ES-60W's hardware button into a scan.sh run.
//
// The Epson ICA driver catches the button itself and sends an Apple Event
// ('EPsc'/'OPtw') to bundle ID com.epson.EventManager. This app claims that ID,
// but TCC blocks delivery: only Epson-signed apps may receive it without a prompt,
// and the driver isn't allowed to prompt. So we also watch the unified log for the
// driver creating that event, which happens before TCC gets a say.
// The driver only runs while a client holds a session, so we keep one open and
// release it for the duration of each scan (scanline needs the device to itself).
import AppKit
import ImageCaptureCore
import os

let log = Logger(subsystem: "local.scanbutton", category: "main")
let pushScanEvent = (eventClass: AEEventClass(0x45507363), eventID: AEEventID(0x4F507477)) // 'EPsc', 'OPtw'
let debounce: TimeInterval = 3

final class Receiver: NSObject, NSApplicationDelegate, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    let browser = ICDeviceBrowser()
    let script: String
    var scanner: ICScannerDevice?
    var scanning = false
    var lastPress = Date.distantPast

    init(script: String) { self.script = script }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handlePush(_:reply:)),
            forEventClass: pushScanEvent.eventClass, andEventID: pushScanEvent.eventID)
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        watchDriverLog()
        watchSignal()
        log.notice("started; script=\(self.script, privacy: .public)")
    }

    @objc func handlePush(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        log.notice("button Apple Event: \(event.description, privacy: .public)")
        buttonPressed()
    }

    func watchDriverLog() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--level", "debug", "--style", "compact", "--predicate",
                       #"process == "EPSON Scanner 2" AND eventMessage CONTAINS "(EPsc,OPtw""#]
        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            // Require AECreateAppleEvent too: log's "Filtering the log data using …"
            // header echoes the predicate, which contains "(EPsc,OPtw".
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard text.split(separator: "\n").contains(where: {
                $0.contains("AECreateAppleEvent") && $0.contains("(EPsc,OPtw")
            }) else { return }
            DispatchQueue.main.async { self?.buttonPressed() }
        }
        p.terminationHandler = { _ in
            log.error("log stream exited; restarting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.watchDriverLog() }
        }
        do { try p.run() } catch { fatalError("cannot start log stream: \(error)") }
    }

    // scan.sh sends SIGUSR1 when we hold the scanner, so the hotkey still works.
    var signalSource: DispatchSourceSignal?
    func watchSignal() {
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in
            log.notice("scan requested via SIGUSR1")
            self?.buttonPressed()
        }
        src.resume()
        signalSource = src
    }

    func buttonPressed() {
        log.notice("button pressed")
        guard !scanning, Date().timeIntervalSince(lastPress) > debounce else {
            log.notice("ignored (busy or bounce)")
            return
        }
        lastPress = Date()
        scanning = true
        scanner?.requestCloseSession()
    }

    // MARK: session lifecycle

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard scanner == nil, let s = device as? ICScannerDevice else { return }
        scanner = s
        s.delegate = self
        s.requestOpenSession()
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device === scanner { scanner = nil }
    }
    func didRemove(_ device: ICDevice) { if device === scanner { scanner = nil } }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { log.error("open session failed: \(error.localizedDescription, privacy: .public)") }
        else { log.notice("session open; waiting for button") }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard scanning else { return }
        runScan { [weak self] in
            self?.scanning = false
            self?.scanner?.requestOpenSession()
        }
    }

    func runScan(then done: @escaping () -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script]
        p.environment = ProcessInfo.processInfo.environment.merging(["SCANBUTTON": "1"]) { $1 }
        p.terminationHandler = { proc in
            log.notice("scan.sh exited \(proc.terminationStatus)")
            DispatchQueue.main.async(execute: done)
        }
        do { try p.run() } catch {
            log.error("could not run scan.sh: \(error.localizedDescription, privacy: .public)")
            done()
        }
    }
}

guard let script = Bundle.main.object(forInfoDictionaryKey: "ScanScript") as? String,
      FileManager.default.isExecutableFile(atPath: script) else {
    fatalError("ScanScript missing from Info.plist or not executable")
}
let app = NSApplication.shared
let receiver = Receiver(script: script)
app.delegate = receiver
app.setActivationPolicy(.prohibited)
app.run()
