# 版本记录

## v0.2.9 Community Beta（构建 21）

- 从文本、Markdown、PDF 或当前选区提问，按会话选择模型。回答支持本机 Markdown 与 LaTeX 渲染，可以回看来源、筛选历史并导出 Markdown 笔记。
- 公开版使用原创「书签」桌宠，随包提供科研桥 0.2.3、可选 Zotero 10 只读选区扩展 0.1.4 和第三方许可声明。
- 需要另行安装 DSH Desktop 0.2.2-rc.5，并配置自己的模型账号。ChatGPT 私人订阅适配器和授权均不随包提供。标准 DSH 可归档会话，可能没有永久删除功能。

### 安装与兼容性

| 项目 | v0.2.9 |
| --- | --- |
| 下载 | [GitHub Pre-release 附件](https://github.com/mxk021/ResearchCompanion/releases/tag/v0.2.9)，含 `ResearchCompanion-0.2.9-arm64.dmg` 和同名 `.sha256` |
| SHA-256 | `e7ee2d072a18894e85095df5025cd079456245fffd7367c84003096fcc7a9ab2` |
| 系统与架构 | 只验证了 Apple Silicon（arm64），发行机为 macOS 27.2.1。macOS 14.0 是部署目标，尚未在 macOS 14 实机验收。无 Intel 安装包。 |
| 签名 | 包内 App 使用 ad hoc 签名。DMG 容器本身未签名，此版本未经 Apple 公证。首次打开时 Gatekeeper 可能提示无法验证开发者。[安装与手动允许步骤](docs/SETUP.md) |
| 验收范围 | 发行机使用 Command Line Tools，未运行完整 Xcode XCTest。独立 Mac 新用户的交互式首次授权、使用新账号完成提问并导出笔记仍待验收。 |

将两个附件放在同一目录，执行 `shasum -a 256 -c ResearchCompanion-0.2.9-arm64.dmg.sha256`，结果应为 `OK`。打开 DMG，将 App 拖到「应用程序」后，从那里启动并连接自己的 DSH。[安装与首次使用](docs/SETUP.md) · [第三方来源与许可](docs/THIRD_PARTY.md)
