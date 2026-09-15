# M2M Display 项目说明

个人自用的低延迟 Mac 到 Mac 屏幕共享工具，把 MacBook Pro 16"（M1 Pro）的
扩展桌面实时投到 iMac 24"（M1）上，替代延迟感明显的 AirPlay 隔空播放。
两台机器通过雷雳线组成的雷雳桥接网络通信（MacBook Pro = 10.10.10.1，
iMac = 10.10.10.2）。核心指标是鼠标延迟要远低于 AirPlay，实测端到端往返
延迟中位数在 1ms 左右。

## 硬性安全规则

**绝对不要在 MacBook Pro 本地运行接收端角色**（无论是 `M2MReceiverCLI`
还是 `M2MApp` 选择"接收端"）。接收端会创建一个盖满整个屏幕的窗口，把
Dock、菜单栏都隐藏掉。这个规则不是随便定的——已经因为在 MacBook 上误跑
接收端导致过真实的事故（一次需要硬重启才能恢复）。接收端只能通过
`ssh kivi@10.10.10.2` 部署到 iMac 上验证，永远不要在本机测试。

发送端（Sender 角色）在 MacBook 上本地运行是安全的、也是必需的——它是
整个系统的正常工作方式，不会遮挡屏幕。

## 架构

- `M2MSenderCore` / `M2MSenderCLI`：发送端。创建虚拟显示器
  （`CGVirtualDisplay` 私有 API）、用 ScreenCaptureKit 抓屏、VideoToolbox
  硬件编码、通过 Network.framework 把视频发给接收端；同时用 CGEventTap
  监听全局鼠标位置，走一条独立的、不经编解码的 UDP 通道把光标坐标实时发
  过去——这条独立通道是延迟远低于 AirPlay 的核心原因。选择接收端播放声音
  时，通过 Core Audio Process Tap 抓取并静音本机系统音频，再经独立 UDP
  通道发送 PCM；F10/F11/F12 则通过可靠控制通道转发。
- `M2MReceiverCore` / `M2MReceiverCLI`：接收端。监听视频/光标端口，
  VideoToolbox 硬解码后铺满整个物理屏幕显示，收到光标坐标后单独叠加渲染
  原生风格光标；音频使用固定容量环形缓冲和 AVAudioEngine 从 iMac 内建
  扬声器播放，并把音量键命令应用到 iMac 系统音量。
- `M2MApp`：SwiftUI 菜单栏图形界面，两台机器装同一个 App，启动时选角色，
  可以随时开始/停止投屏。用 `scripts/package-m2mapp.sh` 打包成真正的
  `.app`（SPM 不会自动做这件事）。
- `M2MShared`：两端共用的协议定义（`CursorPacket`/`FrameHeader`/
  `AckPacket`）和持久化事件日志 `EventLog`（写到
  `~/Library/Logs/M2MDisplay/`）。

## Git 提交规范

- **提交信息用中文**，命令式标题 + 空行 + 正文说明改了什么、为什么这么改
  （尤其是排查出的根因，不只是表面现象）。
- **作者只有仓库主人自己**，不要加 `Co-Authored-By: Codex` 之类的合作
  作者标记。
- **代码里的文档注释（`///`、`//` 说明性注释）用中文**，解释"为什么"而不是
  "做了什么"（代码本身已经说明做了什么）。
- 例外：临时诊断用的 `print`/`fputs` 调试输出（比如
  `[MouseTap] event #N at ...` 这种）可以保留英文——这是项目里一直以来
  的写法，不算违反规范。
- 只在用户明确要求时才提交/推送，不要主动提交。

## 构建与部署

```bash
swift build -c release
```

发送端（MacBook 本地跑）：
```bash
.build/release/M2MSenderCLI
```

接收端（只能部署到 iMac）：
```bash
scp .build/release/M2MReceiverCLI kivi@10.10.10.2:~/m2mdisplay/M2MReceiverCLI
ssh kivi@10.10.10.2 'ls -la ~/m2mdisplay/M2MReceiverCLI'   # 确认时间戳是刚传的，不是旧文件
ssh kivi@10.10.10.2 'cd ~/m2mdisplay && nohup ./M2MReceiverCLI > receiver.log 2>&1 & disown'
```

图形界面版：
```bash
scripts/package-m2mapp.sh
# 只能 open /Applications 里的正式副本，不要直接打开 .build/M2MApp.app
# （原因见下面"已知的坑"）
```

停止进程时优先用能让代码走到正常收尾逻辑的方式（比如 App 里的"停止投屏"
按钮），而不是无脑 `kill`——普通 SIGTERM 不会触发 Swift 的 `deinit`，
可能会留下没清理干净的虚拟显示器（见下）。

## 已知的坑（排查过、别再踩一遍）

- **虚拟显示器创建有时序竞态**：`CGVirtualDisplay` 注册自定义分辨率模式
  是异步的，创建后立刻查询模式列表有概率查不到，需要带重试。更麻烦的是：
  如果这个创建过程是在主线程、且主运行循环已经在跑的情况下同步调用
  （比如在 SwiftUI 按钮点击里直接调），WindowServer 那边异步注册反而永远
  等不到完成的机会，不管重试多少次都会失败——必须把创建过程放到独立的
  后台 Task 里执行，绝不能堵住调用方线程。
- **虚拟显示器可能变成孤儿**：进程被 `kill`（SIGTERM）而不是走正常的
  `stop()`/`deinit` 时，已创建的虚拟显示器可能不会被系统正确回收，导致
  后续再创建同名虚拟显示器持续失败。表现为 `system_profiler
  SPDisplaysDataType` 里能看到一个 "M2M Display" 条目一直 "Online: Yes"，
  怎么等都不消失。目前发现最有效的解决办法是 `sudo killall WindowServer`
  （需要用户自己在真实终端里输入密码执行，我这边的工具跑不了 sudo）。
- **`NSCursor.arrow.image` 在裸命令行进程里不可靠**：读出来可能是空图像
  （`size=(0,0)`，`cgImage(forProposedRect:)` 返回 `nil`），但在正式 `.app`
  进程中可以正常读取。当前接收端优先使用 AppKit/HIServices 的系统光标资源，
  并保留手绘兜底；测试光标资源时不要只依据裸 CLI 的结果下结论。
- **原生音量 HUD 使用的是私有接口**：`NativeVolumeHUD` 运行时调用
  `OSD.framework` 的 `OSDManager`，该入口不受兼容性保证。系统升级后即使类、
  选择器和方法签名仍存在，调用也可能被系统静默忽略；必须保留并验证自绘
  `VolumeHUDView` 兜底，不能只用“方法存在”判断 HUD 已经显示。
- **`.app` 打包后一秒左右自己退出**：如果 `.build/M2MApp.app` 和
  `/Applications/M2MApp.app` 共用同一个 `CFBundleIdentifier`（比如测试时
  直接 `open` 过 build 目录里那份），macOS 26 的 Control Center 会把
  状态栏图标身份判定为冲突，发送隐藏指令，纯菜单栏 App（没有窗口）收到后
  会把自己退出。`scripts/package-m2mapp.sh` 已经处理了这个问题（唯一
  Bundle ID + 每次打包自动注销 build 目录副本的 LaunchServices 记录），
  但仍然要遵守"只 open /Applications 里的正式副本"这条规则。
- **屏幕录制权限按 Bundle ID 独立授权**：`M2MSenderCLI`（命令行）能用是
  因为借用了启动它的终端 App（比如 Warp）已经被授权过的权限；
  `M2MApp.app` 是独立身份，第一次用需要单独去"系统设置 > 隐私与安全性 >
  屏幕录制"里手动加一次。如果打包时改了 Bundle ID，之前加过的授权会失效，
  需要重新加。
