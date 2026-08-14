import AppKit

setvbuf(stdout, nil, _IOLBF, 0) // line-buffer — this is a long-running daemon; a log tail should see output as it happens, not only at exit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
