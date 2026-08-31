# dock-video-demo

macOS Dock 图标动态渲染实验：把视频帧或 Android 投屏画面实时写入 Dock 图标。

## 工具

| 工具 | 源码 | 功能 |
|------|------|------|
| `dockvideo` | `main.swift` | 循环播放本地视频到 Dock 图标，30fps |
| `dock-scrcpy` | `dock-scrcpy.swift` | 通过 scrcpy 将 Android 设备画面投到 Dock 图标（可多图标拼接），基于 ScreenCaptureKit 捕获 scrcpy 窗口 |

## 构建

```bash
swiftc -O -o dockvideo main.swift
swiftc -O -o dock-scrcpy dock-scrcpy.swift -framework ScreenCaptureKit
```

## 运行

```bash
./dockvideo [video.mp4]   # 默认使用 test.mp4
./start.sh                # 双 Dock 图标模式（推荐）
./dock-scrcpy 0           # 单独启动 master
./dock-scrcpy 1           # 单独启动 viewer
```

依赖：本地 scrcpy 构建 + USB 连接的 Android 设备（adb）。

## dock-scrcpy 架构

master/viewer + 共享内存，单 SCStream：

- **master (index 0)** — 计算所有 crop 的 bounding box，启动 scrcpy 带 `--crop=bbox`（服务端第一次裁剪），用单条 SCStream 捕获 scrcpy 窗口并渲染所有 crop：自己的 crop 直接设为 Dock 图标，其余缩放为 128×128 BGRA 写入 `/tmp/dock-scrcpy-frame-<i>.raw`（mmap + seq 头）。管理 scrcpy 生命周期，提供 Settings 菜单（⌘,）。
- **viewer (index ≥1)** — 纯共享内存读取器，30fps 轮询 seq，变化时更新自己的 Dock 图标，完全不使用 ScreenCaptureKit。
- `start.sh` — 先启动 viewers，再循环运行 master；master 以退出码 2 请求重启（换新进程是修复 SCK 中毒连接的唯一可靠手段）。

## 配置

`~/.config/dock-scrcpy.conf`（JSON），每个 window 条目对应一个 Dock 图标的 crop 区域（Android 屏幕坐标，建议正方形）：

```json
{
  "windows": [
    {"w": 562, "h": 562, "x": 34, "y": 250},
    {"w": 562, "h": 562, "x": 624, "y": 250}
  ]
}
```

可通过 master 的 Settings 菜单（⌘,）修改，保存后重启生效。

## 已知的坑

详见 [CLAUDE.md](CLAUDE.md)，重点：

- scrcpy 窗口不能完全离屏（SDL/Metal 跳过渲染 → SCK 零帧），需留 1px 在屏内
- scrcpy 启动期重建窗口会毒化进程级 SCK 连接，需等窗口稳定 1.5s 再附流，失败换进程
- 重启 Dock 会断开已运行进程的图标更新通道，顺序必须是：停进程 → 重启 Dock → 再启动
- 进程退出前先 `setActivationPolicy(.accessory)`，否则可能留 ghost 图标
