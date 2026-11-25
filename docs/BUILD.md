# 构建与发布

在 Git 的干净检出目录运行以下命令。从源码重建 v0.3.4 时先检出 `v0.3.4` 标签，开发分支可运行同一脚本。需要 macOS、完整 Xcode（含 SwiftPM、XCTest 和当前 macOS SDK）、Python 3.9 或更新版本、Node 和 pnpm。版本要求见 `package.json`，依赖按 `pnpm-lock.yaml` 安装。首次安装锁定依赖需要访问 npm。构建与测试不需要 DSH 登录或模型额度。

```sh
python3 scripts/release.py
(cd dist && shasum -a 256 -c *.sha256)
```

`release.json` 管理 App 版本、bundle ID 和最低系统版本。打包将同一个三段数字版本写入 macOS 的 `CFBundleShortVersionString` 与 `CFBundleVersion`。从旧整数构建号迁移时，退出 App 后原位替换安装包，在「关于科研助手」核对新版本。科研桥和可选 Zotero 扩展独立维护各自的协议版本。构建当前 CPU 架构的 DMG，根据架构单独验证。当前安装包为 arm64。每次输出到空目标，可用 `--output` 指定其他目录。已有本地 pnpm 缓存的维护者可用 `--offline`。

构建在临时目录编译科研桥和 App，运行 Swift、WebKit、PDF、桥协议和 Zotero 测试，检查 App 签名及架构，实际只读挂载并核对安装盘，再生成 SHA-256。运行 AppKit/WebKit 测试需要可用的 macOS 图形登录会话。没有完整 Xcode 的维护机可用 `--clt-only` 构建社区测试包。该选项跳过 XCTest，记录测试结果时请注明。可用 `SDKROOT` 指定已安装且与编译器匹配的 SDK。这些步骤不向 `/Applications` 安装，不访问个人 DSH 配置或调用任何模型。

完整 Xcode 构建沿用 Xcode 管理的 Metal 工具链缓存，使只读挂载独立于测试用的临时 HOME。科研助手的设置和合成会话仍在临时目录。

`Resources/PublicManifest.txt` 逐项列举仓库内允许分发的资源。公开包还包含构建生成的图标、入门说明、科研桥，以及签名后的 PDFium 动态库和该固定构建的完整许可证。个人桌宠素材只用于本机维护。DMG 顶层另有可选的 Zotero 扩展。构建会拒绝重复清单项、意外文件、符号链接及带有构建者 HOME 路径的产物。

打包时按可执行文件架构获取 PDFium 8165 的发布档，并使用 `scripts/pdfium_bundle.py` 中的固定 SHA-256 校验。可用 `--pdfium-archive <发布档路径>` 复用已经下载的同架构档案。`scripts/release.py --offline` 使用这项参数与本地 pnpm 缓存。App 运行、读取论文和裁图均在本机进行。[PDFium 发布档及许可](THIRD_PARTY.md)

如果只更新本机 Zotero 选区扩展，在项目根目录运行 `python3 zotero-context-bridge/build.py --output <暂存目录>/research-companion-context-0.1.6.xpi`。通过 Zotero 插件管理器安装同标识的新版后，可以删除暂存 XPI。

文献验证可把 `scripts/check-paper-sample.swift` 与 App 的 Swift 源一同编译，排除 `DSHPetMain.swift`，通过正常打包脚本组装成临时 App。以命令行运行 App 内可执行文件，传入获准使用的 PDF、题目和空的临时输出目录。核对原页、提取文字、裁图和来源坐标；区分自动结果与人工复查。提交复现时使用合成材料，临时 PDF 和裁图可在验收后清理。

定位复用同一份本地 PDF 索引。明确编号走对象索引，词项问句使用 BM25，复杂问句可让已选模型提出候选检索词。多对象关系优先附上同段引用并保留独立页位。比较裁图时同时核对原页的对象边缘、编号、图注及相邻正文。一个区域能成功定位，仍可能有对象边界错误。

本机打包可用 `--local-signing-keychain <绝对路径>` 和 `--sign-identity <40 位 SHA-1 证书指纹>` 复用本机代码签名证书。该模式将指定要求绑定到 bundle ID 和证书指纹。私钥保存在用户钥匙串，原位升级沿用同一证书和 bundle ID。首次从按 CDHash 识别的 ad hoc 包切换时，需为新签名授权一次。公开包独立构建，默认采用 ad hoc 签名。公证选项另需 Developer ID。[Apple 代码签名要求](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)

同一身份的后续原位升级可用 `--previous-app "/Applications/Research Companion.app" --require-same-identity`。脚本仅在两个包互相满足对方指定要求时产出候选。`--reuse-installed-resources` 会离线复制已严格验签的本机资源和 PDFium，并从当前源码更新对话资源及生成 App 图标。其他资源或框架发生变化时走常规打包。安装后以正式进程的「设置 → 交互与提醒 → 选取文字」授权状态为准。Zotero 只读桥使用已有配对。

使用 `swiftc -parse-as-library scripts/benchmark-transcript.swift -o <临时可执行文件>` 编译合成基准，再传入 App 内的 `Contents/Resources/Transcript`。它测量 90 条历史的初次排版、72 次流式更新以及滚动后同步布局。比较版本时保持参数和设备相同。文档问答的客户端单调时钟可从本机 `research-timing` 日志读取。模型入口的科研桥阶段时间单独比较，勿与重叠的客户端区间相加。

App 图标使用 `Resources/AppIcon.png` 的 1024 像素母版。打包脚本生成各尺寸并封装为 `ResearchCompanionWormhole.icns`，也从同一母版提取菜单栏、对话和设置共用的透明符号。

论文请求先区分输出动作、起止原文、对象编号和具名符号。图注、正文、公式及浮动对象沿同一原页坐标索引。跨栏图注需要原文和版面共同支持，图注与引理按独立段落边界分开。公式和定义按需使用内置 PDFium 的字形与页面区域复核，PDFium 字符序号不用于 PDFKit 选区。复杂公式继续保留原页裁图。

`check-paper-sample.swift` 分别记录首次索引、缓存、布局关系、对象定位、PDFium、裁图、完整性检查及应用取证准备。已发送回合的逐项核验状态与原文及区域一起冻结，历史记录缺少此字段仍可正常读取。每次冻结新的独立题库，已揭晓样本只用于回归。

发送前的材料提示与实际发送共用范围判断。文件属性变化时先核对内容摘要，已读索引继续用于相同内容。对象来源可在原页阅读器中切换。Markdown 引用来自经过校验的出处快照，旧会话仍可回跳原页。缺少核验原文的旧回答导出时保留出处信息。裁图可在 App 内查看，Markdown 导出会说明是否内嵌。

已装 DSH Desktop 0.2.2-rc.5 的维护者还可在只读挂载 DMG 后使用同一发行包的组件运行端到端复验。将 `app` 设为实际挂载包的路径。此检查新建临时 HOME、profile 和工作区，运行真实 DSH 服务与合成会话，并检查重启恢复。不会复用本机订阅授权。

```sh
app='/Volumes/Research Companion/Research Companion.app'
bridge_version=$(python3 -c 'import json; print(json.load(open("package.json"))["version"])')
ELECTRON_RUN_AS_NODE=1 '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness' \
  --expose-internals scripts/check-first-install.mjs \
  "$app/Contents/Resources/dsh-research-companion-${bridge_version}.tgz" "$app/Contents/MacOS/ResearchCompanion"
```

如需验证公开版升级，先按发行方提供的 SHA-256 校验 v0.2.11 安装盘，将环境变量 `RC_TEST_UPGRADE_FROM` 指向旧包内的 `dsh-research-companion-0.2.4.tgz`，再执行同一条检查命令。程序在临时 HOME 中先安装旧桥、创建合成会话，正常停服，用正式 CLI 更新到新桥，并验证重启后会话与文档取证能力可用。

还可使用开发工具把 `scripts/check-public-setup.swift` 与 `Sources/DSHPet/ResearchSetup.swift` 一起编译，并设置 `RC_TEST_SETUP_CHECK` 指向生成的检查程序。此时同一次检查还会校验公开包内置归档和连接设置实际识别的安装或升级状态。

## 发布版本

v0.3.4 采用 App 版本号及构建号 `0.3.4`。公开包内的 App 采用 ad hoc 签名，未经 Apple 公证。首次打开可能被 Gatekeeper 拦截，公开包升级或从本机签名包更换为公开包后可能需要重新授予辅助功能权限。常规 CI 只做构建和校验，发布由维护者在仓库中操作。

1. 核对候选提交、版本标签和构建输入。在审核过的干净检出目录运行 `python3 scripts/audit-source.py --history`，检查暂存区与本地引用可达的提交。另行复核截图、第三方声明，以及 GitHub 上的附件、Actions 日志和产物。
2. 核对标签指向实际构建提交，并验证原始镜像。脚本的 `--tag` 只检查版本字符串。已有标签的版本保留原提交和原附件，软件实现变更应更新版本并打新标签。
3. 将通过验证的 DMG 和 `.sha256` 上传到对应 Release。发行说明列出测试环境、签名和公证状态、需另装的宿主、账号要求与实机验收范围。[v0.3.4 发行页](https://github.com/mxk021/ResearchCompanion/releases/tag/v0.3.4)
4. 发布后以该仓库可见性允许的权限重新下载附件。核对 SHA-256，挂载镜像并验证 App 的版本、架构、签名和安装内容。[GitHub Releases](https://github.com/mxk021/ResearchCompanion/releases)

## 可选的 Developer ID 签名与 Apple 公证

准备分发公证版本时，在发行者控制的 Mac 上配置 Developer ID Application 证书。使用 `xcrun notarytool store-credentials` 的交互流程将公证凭据保存到钥匙串。随后从目标版本的干净检出目录执行以下命令。

```sh
python3 scripts/release.py \
  --identity 'Developer ID Application: Your Organization (TEAMID)' \
  --notary-profile research-companion-notary
```

此模式启用 Hardened Runtime 和安全时间戳，签名 App 与 DMG，向 Apple 提交 DMG。收到 `Accepted` 后装订并验证公证票据，检查 Gatekeeper，再计算最终文件的校验和。若提交失败，可通过提交 ID 查询 Apple 诊断。[Apple 公证工作流](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
