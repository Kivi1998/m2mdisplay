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
  过去——这条独立通道是延迟远低于 AirPlay 的核心原因。
- `M2MReceiverCore` / `M2MReceiverCLI`：接收端。监听视频/光标端口，
  VideoToolbox 硬解码后铺满整个物理屏幕显示，收到光标坐标和类型后在独立
  悬浮窗口（`CursorOverlayView`）里叠加渲染对应形状（箭头/手形/工字）。
- `M2MApp`：SwiftUI 菜单栏图形界面，两台机器装同一个 App，启动时选角色，
  可以随时开始/停止投屏。用 `scripts/package-m2mapp.sh` 打包成真正的
  `.app`（SPM 不会自动做这件事）。
- `M2MShared`：两端共用的协议定义（`CursorPacket`/`FrameHeader`/
  `AckPacket`）和持久化事件日志 `EventLog`（写到
  `~/Library/Logs/M2MDisplay/`）。

## Git 提交规范

- **提交信息用中文**，命令式标题 + 空行 + 正文说明改了什么、为什么这么改
  （尤其是排查出的根因，不只是表面现象）。
- **作者只有仓库主人自己**，不要加 `Co-Authored-By: Claude` 之类的合作
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
- **`NSCursor.arrow`/`.iBeam` 的 `.image` 是否可靠取决于进程是不是正经的
  `.app` bundle**：在裸命令行进程（比如直接 `swiftc` 编译出的可执行文件、
  或者 `M2MReceiverCLI` 那种没有 `Info.plist`/Bundle ID 的可执行文件）里读出
  来是空图像（`size=(0,0)`，0 张 representation）；但在真正通过 `open -a`
  启动、有 `Info.plist` 的 `.app` bundle 里（比如 `M2MApp.app`）是能正常读到
  位图的，实测过。`CursorOverlayView.swift` 里箭头用 `NSCursor.arrow.image`
  （配 `.hotSpot`，数值跟下面提到的 hotx/hoty 是同一套坐标系，不用转换），
  读不到时退化成手绘版本兜底——如果哪天改成用 `M2MReceiverCLI` 部署接收端，
  记得箭头会退化成手绘那版，不是 bug。
  手形、工字这两个不经过 `NSCursor`，是直接读系统自带的矢量光标资源文件：
  `/System/Library/Frameworks/ApplicationServices.framework/Versions/A/
  Frameworks/HIServices.framework/Versions/A/Resources/cursors/<name>/`
  下面的 `cursor.pdf`（图形）+ `info.plist`（`hotx`/`hoty` 就是热点，直接当
  "左上角原点、Y 轴向下"的坐标用，不用翻转，已经用真机渲染加标记点验证过）。
  这个路径不是公开 API，是从系统怎么显示这些光标反推出来的，`pointinghand`
  和 `ibeamhorizontal`（注意不是 `ibeamvertical`，那个是竖排文字用的）这两个
  文件夹名字也是试出来的。渲染这个 PDF 时**不能**套用手绘图形那套"先把 Y
  轴翻转过来再画"的变换——PDF 页面本身就是标准的左下角原点、Y 向上，
  照抄手绘那套变换会把图形画成上下颠倒，已经用真实 CALayer 渲染截图验证过，
  两种画法配合 `CALayer.contents` 的表现不一样。换 macOS 大版本这个路径可能
  会挪地方，读不到时（`loadSystemCursorGlyph` 返回 `nil`）会退化成手绘版本，
  不会崩溃或显示空白光标。
  找不到系统自带的箭头资源文件（大概率是直接烧录在 WindowServer 里，不是
  独立文件），只能靠 `NSCursor.arrow.image`，所以箭头这条退化路径更容易触发。
  发送端识别"当前系统光标是哪种类型"用的是另一个 API——`NSCursor.
  currentSystem`（跨进程读取 WindowServer 当前真实显示的光标，不同于只反映
  本 App 光标矩形的 `.current`），它读到的位图不受上面这些坑影响，随时可靠。
  但它返回的对象跟 `.arrow`/`.iBeam`/`.pointingHand` 这些单例不是同一个实例，
  不能用 `===` 身份比较来判断类型，只能靠位图尺寸 + 热点坐标做指纹匹配（见
  `CursorClassifier.swift`）。这组指纹是在当前这台 MacBook Pro、当前这个
  macOS 版本上实测出来的，换系统版本可能会变；指纹匹配不上时会安全退化成
  箭头，不会渲染出错误形状或崩溃，但会退化成"看不出来是手形/工字"——如果
  升级系统后发现手形/工字都不出现了，先怀疑这里，重新跑一遍
  `CursorClassifier.swift` 顶部注释提到的采样方法拿新指纹。
- **`CGDisplayHideCursor` 的隐藏状态会被点击重置**：这是 macOS 自身的固有
  行为，不是这个项目的 bug——只隐藏光标图案挡不住"点一下 iMac 鼠标，刚隐藏的
  原生箭头又冒出来"。真正的解法是投屏期间用 `LocalInputGuard`（`CGEventTap`
  的 `.defaultTap`，不是只能旁听的 `.listenOnly`）把 iMac 本机的鼠标事件在
  派发给任何 App 之前就直接吞掉，点击既然到不了桌面，就没有谁会去触发那个
  重新显示光标的逻辑。这个吞事件的权限比 `MouseTap` 当年用的"输入监控"高一
  级，需要"辅助功能"（Accessibility），跟下面"屏幕录制权限"一样按 Bundle ID
  独立授权，第一次用要单独去加。
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
