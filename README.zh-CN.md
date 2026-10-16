# Pomodoro Art

[English](README.md) | [简体中文](README.zh-CN.md)

一个安静的 macOS 菜单栏番茄钟，提供磨砂玻璃面板、专注与休息计时，以及系统通知。同时包含本地网页版。

需要 **macOS 12 或更高版本**。设置和使用记录保存在本机。

## 安装

安装 Xcode、Node.js 和 Python 3，然后运行：

```sh
git clone https://github.com/wireheadz/PomodoroArt.git
cd PomodoroArt
npm run build:macos
open dist
```

将 **Pomodoro Art.app** 移入「应用程序」文件夹并打开。应用内包含 Node 及其非系统依赖，运行时无需单独安装 Node。构建产物适用于当前 Mac 的架构，使用本地签名，尚未公证。

`dist` 中的 ZIP 在桌面或 iCloud 添加文件元数据之前生成。如遇签名问题，请先在非 iCloud 同步目录解压，再将应用移入「应用程序」。

## 设置与使用

1. 首次启动时，允许 macOS 弹出的通知权限请求。如果已经拒绝，「Enable notifications」会打开系统设置。
2. 点击菜单栏图标展开计时器，拖动滑块调整专注和休息时长，再点击倒计时开始或暂停。
3. 一个阶段结束后，面板会自动从菜单栏图标展开，显示「Start break」或「Start focus」。点击后才会开始下一阶段。

图标始终保持简洁：圆圈中有点表示专注，有横线表示休息，空圆圈表示空闲。点击面板外部可收起面板，计时继续进行。重新打开时，已完成阶段仍会显示完成提示。

为方便测试，专注和休息最短均为 **10 秒**，以 10 秒为步长调整。将滑块拖至最左侧即可设置为 `00:10`。专注最长 60 分钟，休息最长 30 分钟。Mac 应用使用系统通知提示音，没有背景环境音或独立循环闹铃。

点击「Reset」重置当前阶段，点击电源图标退出。

## 网页版

```sh
npm start
```

打开 http://127.0.0.1:4173。网页版保留浏览器内的完成提示音。可通过 `POMODORO_PORT` 更改端口。

## 本地数据与集成

Mac 应用将设置和记录保存在 `~/Library/Application Support/Pomodoro Art/`，网页版使用 `data/`。本地已有的 JSON 数据会用于 Mac 构建首次启动时的初始化；全新克隆使用默认设置和空记录。个人数据、构建产物及缓存不会提交到 Git。

保留现有的 Obsidian 状态与活动日志集成，以及 Mac Live Context 捕获控制集成。`POMODORO_OBSIDIAN_VAULT` 可指定知识库路径，`POMODORO_CAPTURE_CONTROL_FILE` 可指定共享控制文件。默认知识库为 Obsidian iCloud Documents 文件夹中的 `Personal knowledge library`。日志日期目前使用 `Asia/Shanghai` 时区。

## 开发

```sh
npm test
npm run build:macos
```

`macos/` 是原生菜单栏外壳，`index.html` 是计时界面，`server.js` 是本地回环服务器，`scripts/` 包含打包工具。可通过 `POMODORO_NODE_BINARY` 指定其他 Node 运行时。重新构建前请先退出正在运行的应用。

## 常见问题

- **没有通知：** 在「系统设置 → 通知」中允许 Pomodoro Art 和提示音。专注模式和睡眠可能延迟通知；唤醒后会按实际经过的时间更新计时。
- **仍然显示旧界面：** 请先退出已安装的应用，再替换为新构建。
- **集成失败：** 检查配置路径。Mac 服务器错误日志位于 `~/Library/Application Support/Pomodoro Art/server.log`。

[反馈问题](https://github.com/wireheadz/PomodoroArt/issues)时，请附上 macOS 版本和复现步骤。

## 卸载

退出 Pomodoro Art，将应用移至废纸篓。本地使用记录仍保留在 Application Support 文件夹中。
