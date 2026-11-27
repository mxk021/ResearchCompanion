# Research Companion · 科研助手

Research Companion 是一款开源文献阅读助手，支持 macOS 和 Windows。关联 PDF、纯文本或 Markdown 后，可以结合原文连续追问，按页码、章节或原句定位证据，并将回答和公式保存为 Markdown 笔记。模型和会话由 DeepSeek Harness Desktop（DSH）提供。

## 安装

0.4.2 是双平台整合候选。两端共用科研桥 0.2.9 和可选的 Zotero 10 只读扩展 0.1.7。安装候选时，请核对同目录的 SHA-256 文件。

| 平台 | 候选安装包 | 系统与签名 |
| --- | --- | --- |
| Apple Silicon Mac | `ResearchCompanion-0.4.2-arm64.dmg` | 最低部署目标为 macOS 14.0。公开构型采用 ad hoc 签名，未经 Apple 公证。首次打开及更新后可能需要单独确认权限。 |
| Windows x64 | `ResearchCompanion-0.4.2-win-x64-candidate-setup.exe` | 已有验收覆盖 Windows 11 x64，需要 WebView2 Evergreen Runtime。候选安装程序未经 Authenticode 签名。 |

另行安装兼容的 **DSH Desktop 0.2.2-rc.5** 并配置自己的模型账号。[macOS 安装](docs/SETUP.md) · [Windows 安装](windows/README.md) · [macOS v0.3.4 正式发行](https://github.com/mxk021/ResearchCompanion/releases/tag/v0.3.4)

## 阅读、核对和保存

- 从窗口菜单、macOS 菜单栏或 Windows 系统托盘唤回并固定科研窗口。固定设置会在重启后恢复。
- 在原应用选中文字，然后点「选取文字」。macOS 还提供系统文字服务。核对预览后，可输入翻译、解释或其他要求。WPS 回退到原生复制时，可能替换或清空系统剪贴板。取词前请保存重要的剪贴板内容。部分阅读器需按界面提示手动复制再粘贴。
- 已关联的 PDF 可按页、原句起止及图表公式编号定位。扫描页可使用系统 OCR。普通追问可结合会话和已核验摘录，缺少证据时会标注。逐字引用及按原文翻译需要核验原文。支持图像的会话模型可在同一轮处理文件证据、选区和用户附图。
- 在回答中点「打开原文」核对页位，或点「来源详情」读取当轮摘录。多栏阅读顺序、跨页图注、扫描页和复杂公式可能无法完整核验。引用到笔记或论文前，请对照原页检查。无法取词时，仍可向已关联的文件提问。
- 回答支持本机 Markdown 和 LaTeX 排版。通过回答菜单保存笔记，或按标题、材料和归档状态查找历史。永久删除仅在宿主明确提供相应能力时可用。

## 模型与数据

PDF 索引、OCR、取词和笔记渲染在本机执行。提交问题时，DSH 会将所需的会话上下文、摘录、裁图和用户附图发送给选定的模型提供方，费用及额度取决于你的账号。候选安装包不包含私人订阅适配器、凭据或个人工作区。[模型账号和数据说明](docs/SETUP.md#连接及数据)

## 参与开发

请用合成材料提供复现步骤，并移除凭据、私人路径和文献内容。[报告问题](https://github.com/mxk021/ResearchCompanion/issues/new?template=bug_report.md) · [贡献指南](CONTRIBUTING.md) · [构建与测试](docs/BUILD.md) · [版本记录](CHANGELOG.md)

Research Companion 是独立项目，与 DSH、OpenAI 和 Zotero 无官方隶属关系。项目代码采用 MIT 许可证，字体和其他第三方组件保留各自的许可声明。[MIT 许可证](LICENSE) · [第三方来源与许可](docs/THIRD_PARTY.md)
