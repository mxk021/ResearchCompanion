# 参与 Research Companion

欢迎报告使用中遇到的问题、修正文档或提交代码改进。报告问题前可先搜索已有 Issues，同一问题可补充自己的环境和复现步骤。[查看 Issues](https://github.com/mxk021/ResearchCompanion/issues) · [提交 Bug Report](https://github.com/mxk021/ResearchCompanion/issues/new?template=bug_report.md)

## 从源码开始

1. Fork 仓库，克隆自己的副本，从 `main` 建立工作分支。
2. 按改动选择入口。macOS 应用使用 Swift，DSH 科研桥使用 TypeScript，Zotero 选区扩展单独构建。[macOS 应用](Sources/DSHPet/) · [科研桥](src/) · [Zotero 扩展](zotero-context-bridge/)
3. 运行与改动相关的测试。用 `pnpm install --frozen-lockfile --ignore-scripts` 安装锁定的 Node 依赖后，可用 `pnpm typecheck` 检查 TypeScript。Zotero 单元测试可单独运行 `node --test zotero-context-bridge/tests/bridge.test.cjs`。完整构建由 `python3 scripts/release.py` 驱动，所需 macOS、Xcode、Node 和 pnpm 版本见构建文档。[构建与测试](docs/BUILD.md)
4. 向上游 `main` 提交 Pull Request，写明修改原因、用户可见变化、已运行的测试和仍待验证的环境。若修复了已报告的问题，请关联相应 Issue。[Pull Requests](https://github.com/mxk021/ResearchCompanion/pulls)

## 示例与第三方内容

请用自己编写的短文或合成数据复现问题。提交截图、日志摘录和测试夹具前，移除私人路径、论文原文、会话内容、凭据与账号标识。新增第三方代码、字体或图片时，给出来源、版本和允许再分发的许可，并补齐随包声明。[项目 MIT 许可证](LICENSE) · [第三方来源与许可](docs/THIRD_PARTY.md)
