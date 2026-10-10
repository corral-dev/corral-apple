# simctl 安装 / 启动 / 截图卡住（多运行时同开）

> 症状：`xcrun simctl install|launch|io screenshot` 长时间无输出、脚本挂死，或同名设备在多个 iOS 运行时下同时 Booted。

## 现象

- `scripts/ios_sim.sh run` 或 `simctl launch` / `simctl io … screenshot` 卡住数十秒到数分钟无结果。
- `xcrun simctl list devices booted` 里同时有多条 Booted（例如 iOS 26.2 与 iOS 27.0 各一台「iPhone 17」）。

## 原因

同一台 Mac 上多个 CoreSimulator 运行时同时 Booted 时，`simctl` 部分子命令会互相抢锁或排队，表现为假死，而不是立刻报错。

## 解法

1. 只保留目标运行时的一台设备 Booted，关掉其余：

   ```bash
   xcrun simctl list devices booted
   xcrun simctl shutdown <多余设备的 UDID>
   ```

2. 清掉卡住的客户端：

   ```bash
   pkill -f "xcrun simctl" || true
   ```

3. 再对**唯一 Booted** 的 UDID 执行 install / launch / screenshot。

4. 若仍挂：退出 Simulator.app，对目标 UDID `shutdown` 后再 `boot`，然后重试。

## 预防

- 日常只开一个模拟器运行时做 corral 验收。
- 需要 iOS 27 预览时，先关掉 iOS 26 设备，避免「同名双开」。

<!-- 该文档整理/压缩于 2026-09-05 -->
