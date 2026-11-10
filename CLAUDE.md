# moyu-player

macOS Dock 图标动态渲染实验。把 Android/iPhone 投屏画面实时写入 Dock 图标。

## 工具

- **dock-scrcpy** (`dock-scrcpy.swift`) — 投屏 Android/iPhone 设备画面到 Dock 图标。Android 走 scrcpy + ScreenCaptureKit 捕获 scrcpy 窗口；iPhone 走 AVFoundation 直接捕获 USB 设备画面（无需 scrcpy）

## 构建

```bash
swiftc -O -o dock-scrcpy dock-scrcpy.swift -framework ScreenCaptureKit -framework AVFoundation -framework CoreMediaIO
```

## 依赖

- `screen-power/screen-power.jar`：黑屏切换用的 dex（仓库里放的是预编译版）。改了 `ScreenPower.java` 需重编：`javac --release 11 -cp $ANDROID_SDK/platforms/android-36/android.jar -d /tmp/sp ScreenPower.java && d8 --min-api 21 --output /tmp/sp /tmp/sp/ScreenPower.class && (cd /tmp/sp && zip screen-power.jar classes.dex)`

- Android 模式：依赖 `../3rd/android-testing/scrcpy` 下的本地 scrcpy 构建（通过 `./run` 脚本启动），可用 `SCRCPY_DIR` 环境变量覆盖路径，需要 USB 连接的 Android 设备（adb）
- iPhone 模式：需要 USB 连接的 iPhone/iPad，无需额外工具（AVFoundation + CoreMediaIO 直接捕获）
- 启动时自动检测：优先找 iPhone/iPad，没有则走 Android

## 运行

```bash
./start.sh                       # 启动双 Dock 图标模式（推荐）
./dock-scrcpy 0                  # 单独启动 master（启动 scrcpy + 捕获渲染 + 发布共享内存帧）
./dock-scrcpy 1                  # 单独启动 viewer（读共享内存渲染 crop[1]，会等待 master）
```

## dock-scrcpy 架构

master/viewer + 共享内存。两种捕获模式自动切换：

- **iOS 模式** — 检测到 USB 连接的 iPhone/iPad 时启用。master 通过 AVFoundation `AVCaptureSession` 直接捕获设备屏幕画面（`CoreMediaIO` 启用 iOS 设备发现），帧回调走同一个 `processFrame` 路径。不启动 scrcpy、不用 SCK、不依赖 adb。bboxOverride 在首帧时设为设备全屏分辨率，crop 坐标直接对应设备屏幕像素。限制：无触控反馈（iOS 无公开远程触控注入接口），Dock 图标点击无操作。
- **Android 模式（默认）** — 无 iOS 设备时走此路径。master 计算所有 crop 的 bounding box，启动 scrcpy 带 `--crop=bbox`（服务端第一次裁剪），用**单条** SCStream 捕获 scrcpy 窗口，渲染所有 crop。Dock 图标点击 → `adb shell input tap` crop 中心实现暂停/播放。
- **master (index 0)** — 自己的 crop 直接设为 Dock 图标，其余 crop 缩放到 128×128 BGRA 写入 `/tmp/dock-scrcpy-frame-<i>.raw`（mmap，头部 seq 计数器）。管理 scrcpy 生命周期（Android 模式），提供 Settings 菜单（⌘,）。每 5s `adb shell dumpsys power` 轮询 `mWakefulness`（仅 Android 模式）：熄屏 → 停 SCStream 省电 + 广播伪装图标（index 0 → Phone.app、index 1+ → Photos.app 的系统图标，加载失败回退 moon）；亮屏 → 重新 startCapture（scheduleRetry 在 `screenOffPaused` 时被抑制，避免误重试）。
- **viewer (index ≥1)** — 纯共享内存读取器，**120Hz 轮询 seq 头**（8 字节读，廉价），变化才拷贝像素并更新 Dock 图标；拷贝后复核 seq 防撕裂。**完全不碰 ScreenCaptureKit**。启动显示 hourglass 占位，10s 无新帧显示 iphone.slash。（曾用 30Hz 轮询：与 master 的 30fps 推帧成两个自由时钟，相位差最多一整帧且拍频跳帧，肉眼可见一个图标恒定慢半拍——勿回退）
- **状态占位图标** — `placeholderContext(symbol)` 生成深灰底 + 白色 SF Symbol 的 128×128 帧；master 的 `broadcastPlaceholder` 同时设自己图标并写入所有 viewer shm。启动 hourglass、无 adb 设备 / masterFail 时 iphone.slash、熄屏时显示伪装图标（Phone/Photos，`broadcastSleepCamo`）。
- `start.sh` — 循环体内每轮读配置数、**先起 master 并等它在 LaunchServices 里变成 Foreground（`lsappinfo`），再依次起 viewer**（Dock 按注册顺序从左往右排，先起 viewer 会导致左右画面颠倒），停 viewer 时 `wait` 到真正退出（否则新 viewer 撞单例锁）。master 以退出码 2 请求重启（新进程是修复 SCK 中毒连接的唯一可靠手段）。Settings Apply 也以 exit(2) 走此路径热生效（含窗口数变化）。
- **断连自愈** — scrcpy 退出（如 USB 断开）→ master exit(2) → start.sh 重启；新 master 启动前先等 adb 有设备：无设备则 `adb kill-server` + `start-server`，等 10 秒重试，循环直到设备回来。
- **手机黑屏控制** — 配置项 `turnScreenOff`（Settings 里"启动时关闭手机屏幕"）决定 scrcpy 是否带 `--turn-screen-off`。菜单"黑屏"（⌘D）/"亮屏"（⌘⇧D）运行时切换：**只关面板、设备保持 Awake、投屏不断**，与启动时的黑屏同一机制——`adb shell CLASSPATH=dock-scrcpy-power.jar:dock-scrcpy-server.jar app_process / ScreenPower on|off`，`screen-power/ScreenPower.java` 反射调用 scrcpy-server 的 `Device.setDisplayPower`。两个 jar 由 master 启动时 push 到 `/data/local/tmp/`（scrcpy 启动后会删自己的 server jar，所以用自己的文件名）。调用失败才退回 `input keyevent 26`（真睡眠）。正常退出自动亮屏。
- **重启退避** — start.sh 检测连续快速死亡（<30s）：连续 5 次后每轮 sleep 30s，避免持续性故障（如录屏权限被撤销）导致的重启风暴。
- **熄屏心跳** — 熄屏暂停期间 master 每 5s 重新广播伪装图标（seq 递增），防止 viewer 的 10s 无帧检测误报断连。

### 捕获链路的坑（已修，勿回退）

- **CGEvent `postToPid` 给 scrcpy 发 MOD+o 快捷键无效**（实测：AX 已授权、补全左 Alt flagsChanged 序列也不行，后台 SDL 窗口收不到）。黑屏切换必须走 `ScreenPower` dex，勿回退。
- **adb 读不到"仅关面板"状态**：SurfaceFlinger `powerMode` 仍为 On、`mWakefulness` 仍为 Awake。面板状态只能自己记（`deviceScreenIsOff`），且 Awake 轮询不能清它（旧 bug：启动 5s 后状态被冲掉，"亮屏"点了直接 return）。

- **scrcpy 窗口不能完全离屏**（如 `-32000`）：SDL/Metal 对不可见窗口跳过渲染，窗口不被合成，SCK 零帧（`screencapture -l` 也取不到图）。现在窗口留 1px 在屏幕右下角。
- **scrcpy 自己的 Dock 图标**：用环境变量 `SDL_MAC_BACKGROUND_APP=1` 让 SDL 以 accessory 模式运行，不出现在 Dock。
- **scrcpy 启动期会重建窗口**：过早附上的 SCStream 会以 -3805 死掉，甚至静默无帧且**毒化整个进程的 SCK 连接**（同进程内新建 stream 也永远无帧，只有换进程能恢复）。对策：等窗口 id+尺寸稳定 1.5 秒再附流；stream 死亡/看门狗 4 秒无帧 → 重试；重试 3 次仍失败 → exit(2) 由 start.sh 重启。
- **多进程各开一条流捕同一窗口**是旧架构黑屏的根源之一，勿恢复。
- **`SCScreenshotManager.captureImage` 在 macOS 26 上对该窗口挂起不返回**，逐帧截图方案不可用。
- 杀 scrcpy 要用**从捕获窗口解析的真实 PID**（`SCWindow.owningApplication`），`Process` 句柄只是外层 bash/run 脚本，terminate 它会留孤儿。

### Dock 本身的坑

- **单例**：每个 index 启动即 `flock /tmp/dock-scrcpy-<i>.lock`（O_CLOEXEC，防 scrcpy 子进程继承），已被占用直接 exit(0)、不出 Dock 图标。防止误点 Dock/Finder 里的 exec 图标拉起第二个 master 杀掉正在跑的 scrcpy。
- **SIGHUP 必须接管**：关闭跑 start.sh 的终端会发 HUP，默认动作直接杀进程、不摘 Dock 图标。现在 INT/TERM/HUP 都走 `NSApp.terminate`，start.sh 也 trap HUP。
- **scrcpy 不理 SIGTERM**（实测 15s+ 仍存活），只发 TERM 会留孤儿 scrcpy（窗口同名，干扰下次 `findStableWindow`）。`killHard`：TERM → 1s 后仍活着就 SIGKILL，`stopScrcpy` / `killStaleScrcpy` 都走它。

- **重启 Dock 会断开已运行进程的图标更新通道**（`applicationIconImage` 设了也不生效）。需要重启 Dock 时顺序必须是：停 dock-scrcpy → 重启 Dock → 再启动 dock-scrcpy。
- **Dock "最近使用的 App" 区会堆积 exec 僵尸图标**（dock-scrcpy 每次退出都进 recents，且持久化、Dock 重启不清）。且 **Dock 被 SIGTERM 杀时会把内存里的旧配置回写 prefs**，覆盖掉 `defaults write`——改 Dock 配置必须 `defaults write` 后立刻 `kill -9 <Dock pid>`。当前已关闭 recents（恢复：`defaults write com.apple.dock show-recents -bool true`）。
- **进程退出前先 `setActivationPolicy(.accessory)` 摘掉自己的 Dock 图标**，否则突然退出可能留 ghost tile。
- **清理 scrcpy 必须递归杀进程树**（bash → run → scrcpy 三层）：启动初期 `scrcpyWindowPID` 尚未从窗口解析出来，只 terminate `Process` 句柄会留 scrcpy 孤儿（代码里 `processTree` + `killHard`）。

## 配置

`~/.config/dock-scrcpy.conf`，JSON 格式。当前值（针对 1220×2656 屏、主屏顶部视频 widget x 33–1187 / y 198–864，带 Dock 缝隙补偿——两块采样区中间留 28px 不采，对应图标间的物理缝隙，画面视觉连续）：

```json
{
  "windows": [
    {"w": 562, "h": 562, "x": 34, "y": 250},
    {"w": 562, "h": 562, "x": 624, "y": 250}
  ]
}
```

- 每个 window 条目对应一个 Dock 图标实例的 crop 区域（Android 屏幕坐标）。**给正方形**：非正方形会被中心裁成正方形，等于浪费采样面积
- 旧值备份在 `~/.config/dock-scrcpy.conf.bak`（267×534 竖条 ×2）
- 通过 master 的 Settings 菜单（⌘,）修改：每个 Window 有"框选…"按钮，adb `screencap` 截手机屏幕后在截图上拖拽框选（强制正方形、自动 clamp 到屏幕内），Apply 后 exit(2) 由 start.sh 自动重启生效
- 兼容旧格式（每行一个 `W:H:X:Y`），首次读取自动迁移为 JSON

已安装为 `/Applications/dock-scrcpy.app`（symlink wrapper + scrcpy 图标）。
