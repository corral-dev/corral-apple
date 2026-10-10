# 助手官方标识来源

归一化只做：透明底、等比例缩放、居中、统一留白。禁止改色、拉伸、重绘。

浅色底 / 深色底两套均来自官方。仅下列两处是**同一官方轮廓换官方规定填色**（几何未改）：

- Codex 深色底：OpenAI 2025 符号由默认黑填改为白填（品牌页深浅两套同轮廓）
- Pi 浅色底：官方白标改为 favicon 同款 `#09090b`（官方只提供给深色底用的白标）

| 助手 | 浅色底文件 | 深色底文件 | 官方来源 |
|------|------------|------------|----------|
| Claude | `source/claude.svg` | 同左（陶土色火花，深浅都能认） | Anthropic 品牌火花（Clay） |
| Codex | `source/codex-light.svg` | `source/codex-dark.svg` | OpenAI 2025 符号（Wikimedia 转自 openai.com/brand） |
| Cursor | `source/cursor-light.svg` | `source/cursor-dark.svg` | [cursor.com/brand](https://cursor.com/brand) 立方体 |
| Kimi | `source/kimi-light.svg` | `source/kimi-dark.svg` | [Moonshot 品牌指南](https://moonshotai.github.io/Branding-Guide/)「K Only」 |
| OpenCode | `source/opencode-light.svg` | `source/opencode-dark.svg` | [opencode.ai/brand](https://opencode.ai/brand) 方形标 |
| Pi | `source/pi-light.svg` | `source/pi-dark.svg` | [pi-website `src/logo.svg`](https://github.com/earendil-works/pi-website) |

重跑归一化：

```bash
python3 design/runtime-logos/normalize.py
```
