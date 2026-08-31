# dock-video-demo

macOS Dock 图标动态渲染实验。把视频帧或 Android 投屏画面实时写入 Dock 图标。

## 工具

- **dockvideo** (`main.swift`) — 播放本地视频文件到 Dock 图标，循环播放，30fps
- **dock-scrcpy** (`dock-scrcpy.swift`) — 通过 scrcpy 投屏 Android 设备画面到 Dock 图标，用 ScreenCaptureKit 捕获 scrcpy 窗口

## 构建

```bash
# dockvideo
swiftc -O -o dockvideo main.swift

# dock-scrcpy
swiftc -O -o dock-scrcpy dock-scrcpy.swift -framework ScreenCaptureKit
```

## 依赖

- dock-scrcpy 依赖 `../3rd/android-testing/scrcpy` 下的本地 scrcpy 构建（通过 `./run` 脚本启动）
- 需要 USB 连接的 Android 设备（adb）

## 运行

```bash
./dockvideo [video.mp4]          # 默认使用 test.mp4
./start.sh                       # 启动双 Dock 图标模式（推荐）
./dock-scrcpy 0                  # 单独启动 master（启动 scrcpy + 捕获渲染 + 发布共享内存帧）
./dock-scrcpy 1                  # 单独启动 viewer（读共享内存渲染 crop[1]，会等待 master）
```

## dock-scrcpy 架构

master/viewer + 共享内存，单 SCK 流：

- **master (index 0)** — 计算所有 crop 的 bounding box，启动 scrcpy 带 `--crop=bbox`（服务端第一次裁剪），用**单条** SCStream 捕获 scrcpy 窗口，渲染所有 crop：自己的 crop 直接设为 Dock 图标，其余 crop 缩放到 128×128 BGRA 写入 `/tmp/dock-scrcpy-frame-<i>.raw`（mmap，头部 seq 计数器）。管理 scrcpy 生命周期，提供 Settings 菜单（⌘,）。
- **viewer (index ≥1)** — 纯共享内存读取器，30fps 轮询 seq，变化时把像素设为自己的 Dock 图标。**完全不碰 ScreenCaptureKit**。
- `start.sh` — 先启动 viewers（独立等待 master），再循环运行 master：master 以退出码 2 请求重启（新进程是修复 SCK 中毒连接的唯一可靠手段）。
- **断连自愈** — scrcpy 退出（如 USB 断开）→ master exit(2) → start.sh 重启；新 master 启动前先等 adb 有设备：无设备则 `adb kill-server` + `start-server`，等 10 秒重试，循环直到设备回来。

### 捕获链路的坑（已修，勿回退）

- **scrcpy 窗口不能完全离屏**（如 `-32000`）：SDL/Metal 对不可见窗口跳过渲染，窗口不被合成，SCK 零帧（`screencapture -l` 也取不到图）。现在窗口留 1px 在屏幕右下角。
- **scrcpy 自己的 Dock 图标**：用环境变量 `SDL_MAC_BACKGROUND_APP=1` 让 SDL 以 accessory 模式运行，不出现在 Dock。
- **scrcpy 启动期会重建窗口**：过早附上的 SCStream 会以 -3805 死掉，甚至静默无帧且**毒化整个进程的 SCK 连接**（同进程内新建 stream 也永远无帧，只有换进程能恢复）。对策：等窗口 id+尺寸稳定 1.5 秒再附流；stream 死亡/看门狗 4 秒无帧 → 重试；重试 3 次仍失败 → exit(2) 由 start.sh 重启。
- **多进程各开一条流捕同一窗口**是旧架构黑屏的根源之一，勿恢复。
- **`SCScreenshotManager.captureImage` 在 macOS 26 上对该窗口挂起不返回**，逐帧截图方案不可用。
- 杀 scrcpy 要用**从捕获窗口解析的真实 PID**（`SCWindow.owningApplication`），`Process` 句柄只是外层 bash/run 脚本，terminate 它会留孤儿。

### Dock 本身的坑

- **重启 Dock 会断开已运行进程的图标更新通道**（`applicationIconImage` 设了也不生效）。需要重启 Dock 时顺序必须是：停 dock-scrcpy → 重启 Dock → 再启动 dock-scrcpy。
- **Dock "最近使用的 App" 区会堆积 exec 僵尸图标**（dock-scrcpy 每次退出都进 recents，且持久化、Dock 重启不清）。且 **Dock 被 SIGTERM 杀时会把内存里的旧配置回写 prefs**，覆盖掉 `defaults write`——改 Dock 配置必须 `defaults write` 后立刻 `kill -9 <Dock pid>`。当前已关闭 recents（恢复：`defaults write com.apple.dock show-recents -bool true`）。
- **进程退出前先 `setActivationPolicy(.accessory)` 摘掉自己的 Dock 图标**，否则突然退出可能留 ghost tile。
- **清理 scrcpy 必须递归杀进程树**（bash → run → scrcpy 三层）：启动初期 `scrcpyWindowPID` 尚未从窗口解析出来，只 terminate `Process` 句柄会留 scrcpy 孤儿（代码里 `killTree`）。

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
- 通过 master 的 Settings 菜单（⌘,）修改，保存后需重启生效
- 兼容旧格式（每行一个 `W:H:X:Y`），首次读取自动迁移为 JSON

已安装为 `/Applications/dock-scrcpy.app`（symlink wrapper + scrcpy 图标）。
