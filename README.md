# Research Companion · 科研助手

Research Companion 是一款开源的 macOS 文献阅读助手。关联 PDF、纯文本或 Markdown，按页码、章节或原句定位证据，结合原文提问，再把回答和公式存成 Markdown 笔记。模型和会话由你安装的 DeepSeek Harness Desktop（DSH）提供。

## 安装 v0.3.0

公开安装包适用于 Apple Silicon（arm64）。最低部署目标为 macOS 14.0，实机验收范围见发行说明。App 采用 ad hoc 签名，未经 Apple 公证，首次打开可能需要在系统设置中单独允许。取词的辅助功能权限也可能在更新后重新授权。[v0.3.0 发行页](https://github.com/mxk021/ResearchCompanion/releases/tag/v0.3.0) · [安装和首次使用](docs/SETUP.md)

1. 从发行页下载 `ResearchCompanion-0.3.0-arm64.dmg` 与同名 `.sha256`。把两个文件放在同一目录，运行 `shasum -a 256 -c ResearchCompanion-0.3.0-arm64.dmg.sha256`，确认结果为 `OK`。
2. 打开安装镜像，把 **Research Companion** 拖到「应用程序」。另行安装兼容的 **DSH Desktop 0.2.2-rc.5**，启动一次后正常退出。打开科研助手，在「连接设置」中点「安装科研桥」或「更新科研桥」，再启动 DSH 并配置自己的模型账号。[DSH 官方下载](https://www.deepseek.com/harness/) · [安装与升级步骤](docs/SETUP.md)
3. 选择一份 PDF、文本或 Markdown，等待材料就绪。选定模型后，在输入框提出问题。Zotero 10 用户也可安装镜像内的 0.1.6 版只读选区扩展。[可选的 Zotero 设置](docs/SETUP.md#可选的系统权限和-zotero)

## 阅读、核对和保存

- 在原应用选中文字，然后点科研助手的「选取文字」，或使用原应用的「服务 → 选取文字（科研助手）」。核对预览后，可输入翻译、解释或其他要求。WPS 的原生自动复制会改变通用剪贴板。部分阅读器需按界面提示手动复制再粘贴。
- 已关联的 PDF 可按页、栏、章节、原句起止及图表公式编号定位。可按需对扫描页执行本机 OCR。可在同一轮使用选区和相关文件证据。多段翻译或分析请先查看请求计划，确认范围和模型。
- 在回答中点「打开原文」核对可用页位，或点「来源」读取当轮摘录。格式复杂的页面会存在边界歧义，遇到待核对或出处未核验的提示，请查看原页。无法取词时，仍可向已关联的文件提问。
- 回答支持本机 Markdown 和 LaTeX 排版。通过回答菜单保存笔记，或按标题、材料和归档状态查找历史。永久删除仅在宿主明确提供相应能力时可用。

## 模型与数据

PDF 索引、OCR、取词和笔记渲染在本机执行。提交问题或启动由模型协助的检索时，DSH 会将本轮所需的文字、文件概况或原页裁图交给所选模型提供方，费用及额度取决于你的账号。公开安装包只包含应用、科研桥、安装说明和可选 Zotero 扩展。模型账户和兼容提供方由用户自行配置。[模型账号和数据说明](docs/SETUP.md#连接及数据)

## 参与开发

请用合成材料提供复现步骤，并移除凭据、私人路径和文献内容。[报告问题](https://github.com/mxk021/ResearchCompanion/issues/new?template=bug_report.md) · [贡献指南](CONTRIBUTING.md) · [构建与测试](docs/BUILD.md) · [版本记录](CHANGELOG.md)

Research Companion 是独立项目，与 DSH、OpenAI 和 Zotero 无官方隶属关系。项目代码采用 MIT 许可证，字体和其他第三方组件保留各自的许可声明。[MIT 许可证](LICENSE) · [第三方来源与许可](docs/THIRD_PARTY.md)
