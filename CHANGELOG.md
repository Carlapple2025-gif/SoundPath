# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.1] - 2026-10-26

### 修复

- 接管 App 后原声仍可能从原输出播放（尤其默认输出是 AirPlay / HomePod 时，会出现两边同时响）：
  Tap 静音模式从 `.mutedWhenTapped` 改为 `.muted`，接管期间强制静音源进程
- macOS 26+ 启用 `processRestoreEnabled`：Chrome / Safari 的 helper 进程重启后仍会被 Tap 覆盖

### 新增

- `SOUNDPATH_UNIVERSAL=1` 构建 arm64 + x86_64 通用二进制
- `release.sh`：Developer ID 签名、公证、装订票据、可选上传 Release
- `docs/RELEASING.md`：Apple Developer 报名与发版完整步骤
- CI 改为构建通用二进制，提前发现跨架构问题

## [1.0.0] - 2026-10-26

首个公开版本。

### 新增

- 按 App 分配输出设备：Process Tap 捕获音频，私有聚合设备转发，原输出自动静音
- 系统输出一键切换；「全部恢复」立即停止接管
- 每个输出设备可单独调节系统音量（控制中心只给默认出口一条滑杆）
- 接管后的 App 支持 0–150% 软件增益，逐块平滑、拖动不爆音，按 App 持久化
- 每个输出可试听；实时显示接管数量与 App 播放状态
- `--mixer-test` 自测转发增益数学，`--route-test` 可带增益参数验证链路

### 说明

- 仅支持 macOS 14.4 及以上（依赖 Core Audio Process Tap）
- AirPlay 不能作为单个 App 的目标输出（macOS 限制）

[1.0.1]: https://github.com/Carlapple2025-gif/SoundPath/releases/tag/v1.0.1
[1.0.0]: https://github.com/Carlapple2025-gif/SoundPath/releases/tag/v1.0.0
