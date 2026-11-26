# Research Companion Windows x64 实机验收报告

2026-11-26（北京时间）。在本机 Windows x64（系统构建 26300.9818）执行。测试材料为两页合成 PDF、本地 HTML 和 Markdown。Windows 移植起点为 `windows/port-v0.3.4` 的 `6994d1b7100520ba000828fe7e40d8095ea371da`，功能和视觉基准为 macOS v0.3.4 的 `e60a069d4ae5070438fe5ed9c73d90e1b0353e06`。验收以实际观察到的结果为准。

## 交付包

- 安装器文件 `ResearchCompanion-0.3.4-win-x64-candidate-setup.exe`。Windows 应用文件版本及安装注册版本为 `0.3.4.1`。
- 大小 59,969,429 字节。SHA-256 为 `8358d92305579fde2fdda39c676128767b7efd3d77466521e76067a600f55ebd`。
- 当前用户 NSIS 安装器，负载为 x64、自包含 .NET 10、PDFium 8165 及 WebView2 组件。候选包未做 Authenticode 签名。实机使用现有 WebView2 Evergreen。
- 交付为本地候选。复核时远端 `main`、Windows 分支和 `v0.3.4` 标签均与开始时一致。未推送或发布。

## 实机结果

| 项目 | 结果与证据 |
| --- | --- |
| 安装、升级、卸载 | 通过。交付包干净安装 6,536 ms，从原移植提交构建的 Windows 0.3.4 覆盖升级 9,110 ms。卸载核对程序、开始菜单快捷方式及卸载注册项移除。窗口设置、收据和导出的 Markdown 保留。 |
| Windows OCR | 通过两页 PDF 的扫描页测试。WinRT 在本机安装的简体中文识别语言下，从唯一无文字层页识别了 `314159`、`37` 和图注，返回 3 个区域。识别耗时 309 ms，标点存在 OCR 差异。窗口显示识别 1 页，原生栏位与来源位置可回核。 |
| 图、表、公式和原页裁图 | PDFium 原生回归覆盖唯一图号、表号、带标号公式、未知对象、重复范围、裁图像素和旋转页面。实机问答界面分别提交文字页 Figure 1 和扫描页 Figure 2 的 PNG，来源收据验证文本和图像哈希。Figure 1 原页跳转高亮、三根柱和完整图注的独立裁图均已查看。 |
| 文献问答和流式回复 | Windows 界面、DPAPI/HMAC 命名管道及本机合成协议服务端到端通过。Figure 2 用例在等待状态看到首段，约 316 ms，完整回复约 2,828 ms。时间含桌面验收工具取样开销，回包来源是合成服务。 |
| DSH | 官方 Windows `0.2.2-rc.5` 在隔离 web profile 成功安装并加载生产科研桥 `0.2.6`。通过真实命名管道读取协议 v1、唯一科研工作区、流式及裁图能力和模型目录。隔离主机没有配置 DeepSeek 或 ChatGPT 模型。现有 DSH Desktop 配置保持原状，Desktop 真实账号问答和图像路由仍待验收。 |
| Chrome 157.0.8103.79 | 通过。本地 HTML 选区使用全局 `Ctrl+Alt+T` 逐字带入 `The reference pear factor equals exactly 314159.`。 |
| Edge 158.0.4370.45 | 通过原生复制回退。在来宾窗口选择同一条本地 HTML 文字，UIA 层该用例无可用选区，经单次确认后原文逐字匹配。确认到界面显示的取样约 545 ms。来源显示待核对。初次独立 Edge 配置触发系统账号同步提示，后续验收改用来宾窗口。 |
| WPS 12.1.0.29690 | 通过原生复制回退。WPS PDF 测试版的前台外壳为 `wps.exe`，同安装目录的 `wpspdf.exe` 写入剪贴板。修正后单次确认并逐字带入完整合成句，确认到界面显示的取样约 2,167 ms。来源显示待核对。 |
| 手动选区 | 通过。拒绝自动复制后打开「粘贴选区」，通过「从剪贴板粘贴」预览合成原句并带入。应用逐字显示并标明「出处未核验」。此前同场成功授权的复制未免除下一次确认。 |
| Zotero 10.0.8 | 部分通过。使用官方 x64 ZIP 和独立文献库启用了随包 `0.1.6.xpi`。实际端点生成配对文件，无凭据和重放均返回 403，有效配对请求到达阅读器状态检查并返回 409。桌面工具把便携 10.0.8 窗口绑定到系统安装版 9.0.6 的应用标识，未完成活动阅读器非空选区和附件页回跳。 |
| 来源和笔记 | 通过本机合成问答场景。核对「打开原文」「来源详情」「原页裁图」和 Markdown 另存为。保存文件包含当轮问题、`314159`、原始 LaTeX 与图注出处，安装周期后文件哈希一致。 |
| 窗口及外观 | 通过已观察用例。设置置顶时覆盖前台阅读器，升级启动后保持，可解除。实机观察了深色和浅色，并从系统深色切换至浅色。会话及标题栏同步改变。复验空会话图标、暗色材料标签、Markdown 及 KaTeX 排版。窗口首次可见的一次样本为 2,472 ms。 |
| 自动化 | Windows x64 编译无警告、无错误。22 项 PDFium 原生检查、47 项可在 Windows 运行的协议、渲染及 Zotero 检查通过。原全量 Node 套件含 POSIX socket 与权限假设，在 Windows 上仍有失败。 |

## 本轮对等范围

Windows 分支沿用 macOS v0.3.4 的对话资源、图标母版、协议和 PDFium 版本。应用的 Windows 特有代码在 `windows/`。科研桥打包增加了 Windows 专用参数来包含分块，macOS 的调用方式保持原状。

测试覆盖单个明确编号或页码的证据。多栏、跨页图注、复杂公式变量追踪和模型辅助文档规划仍需更大语料覆盖。浏览器用例是本地 HTML。浏览器内置 PDF 阅读器及同一浏览器中受保护文档的覆盖仍待补齐。Zotero 端到端回跳、真实 DSH Desktop 模型请求、跨平台逐像素比较与长时间压力测试均未验收。当前实机结果不足以签收完整 macOS 对等。

## 复验入口

1. 使用仓库锁文件运行 `pnpm build`，再用 `python -X utf8 scripts/package-bridge.py --windows --public --output <归档路径>` 生成桥归档。
2. 使用 .NET SDK 10.0.404 锁定还原 Windows 项目，按 Windows README 运行 `windows/build.py`。使用 NSIS 3.13、Pillow 11.3.0 和固定的 Windows x64 PDFium 8165。
3. 运行 `dotnet run --project windows/tests/PdfEvidence/PdfEvidenceChecks.csproj -- <pdfium.dll 路径>`。在安装过 Windows 识别语言的主机用合成扫描页验证原生 OCR。
4. 用同一候选包执行当前用户干净安装、从基线覆盖及卸载，逐项检查注册信息、快捷方式和数据保留。

基准发布页及平台资料见 [macOS v0.3.4](https://github.com/mxk021/ResearchCompanion/releases/tag/v0.3.4)、[DSH 0.2.2-rc.5 桌面构建说明](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.5/apps/desktop/README.md) 和 [Zotero 官方下载](https://www.zotero.org/download/)。
