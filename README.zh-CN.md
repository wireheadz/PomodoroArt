# Pomodoro Art

[English](README.md) | [简体中文](README.zh-CN.md)

一个 macOS 菜单栏番茄钟，带有磨砂玻璃面板和系统通知。

需要 **macOS 12 或更高版本**。设置和使用记录保存在本机。

## 安装

安装 Xcode，然后运行：

```sh
git clone https://github.com/wireheadz/PomodoroArt.git
cd PomodoroArt
bash scripts/build-app.sh
open dist
```

将 **Pomodoro Art.app** 移入「应用程序」文件夹并打开。构建产物使用本地签名，尚未公证，适用于当前 Mac 的架构。

## 使用

- 首次启动时允许通知。
- 点击菜单栏图标展开计时器。拖动滑块调整时长，点击倒计时开始或暂停。
- 阶段结束后，面板会从菜单栏图标自动展开。点击「Start break」或「Start focus」继续。
- 点击面板外部可收起面板，计时继续。「Reset」重置当前阶段，电源图标用于退出。

图标中有点表示专注，有横线表示休息，空圆圈表示空闲。完成时使用系统通知提示音。

为方便测试，专注和休息最短均为 **10 秒**。普通拖动按整分钟调整；按住 Shift 拖动、在滑块上滚动或使用方向键，可按 10 秒精确调整。专注最长 3 小时，休息最长 30 分钟。

## 数据与权限

设置和记录保存在 `~/Library/Application Support/Pomodoro Art/`，更新应用会保留现有数据。个人数据和构建产物不会提交到 Git。

如果已经拒绝通知权限，「Enable notifications」会打开系统设置。专注模式和睡眠可能延迟通知。

保留现有的 Obsidian 和 Mac Live Context 文件集成。可通过 `POMODORO_OBSIDIAN_VAULT` 和 `POMODORO_CAPTURE_CONTROL_FILE` 指定路径。日志日期使用 `Asia/Shanghai` 时区。

## 开发

```sh
bash scripts/test.sh
bash scripts/build-app.sh
```

`Sources/PomodoroArt/` 包含 macOS 应用和本地存储，`Resources/` 包含应用内界面。替换构建前请先退出应用。
