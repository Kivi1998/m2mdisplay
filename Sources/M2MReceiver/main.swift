import AppKit

setvbuf(stdout, nil, _IOLBF, 0) // 使用行缓冲；常驻进程的日志应实时可见，不能等退出时才刷新

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
