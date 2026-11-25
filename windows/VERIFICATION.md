# Windows x64 候选版验收

基线为公开标签 v0.3.4，提交 e60a069d4ae5070438fe5ed9c73d90e1b0353e06。Windows 移植位于 windows/port-v0.3.4 与独立工作目录。主机只有 Apple Silicon macOS，没有可用的 Windows OS、虚拟机或远程运行器。

因此，下表的「已实现」是源代码状态。「已验证」仅表示指定的独立或构建检查。Windows 安装、运行、真实界面截图、性能和提供方请求均未在 Windows 验收。未合成应用截图代替实机证据。

| 对照项 | Windows 候选实现 | 证据与尚未覆盖 |
| --- | --- | --- |
| 图标和会话外观 | 复用定稿图标母版和 0.3.4 对话 HTML、CSS、Markdown、KaTeX，WPF 页头、材料区、对话区、输入区域，三种主题选项 | 交叉编译。DPI、明暗对比、字体、IME、拖动、滚动、实际视觉一致性待 Windows 验收 |
| 启动、窗口和托盘 | 单实例、可选置顶及持久化、托盘唤回、退出，直接启动 | Windows 窗口、任务栏、多屏及睡眠唤回未实测。macOS 桌宠、自定义角色和阶段状态面板未移植 |
| WPS、Edge、Chrome | UI Automation 文本选区，来源窗口和剪贴板写入核对后选择性自动复制，最后手动粘贴 | 三种真实阅读器均未实测。通用 UIA 没有可靠的浏览器文档 URL。权限隔离、快捷键注入、剪贴板竞争仍需压测 |
| Zotero | HMAC 成对读取当前阅读器，记录附件源和可靠页码，生成受限 Zotero 回跳链接 | 既有扩展协议单测通过。Windows 配对存储、选区边界及回跳未实测 |
| DSH 与模型 | 共享桥与账号模型协议，Windows 私有命名管道与 DPAPI 双向认证，按会话绑定确切提供方、模型和推理档 | 跨平台握手/拒绝单测及本机 macOS 真实 DSH 隔离检查通过。Windows DSH、DPAPI、命名管道、账号配置、真实模型执行均未实测。本版使用会话快照刷新，未达到 macOS 流式更新对等 |
| PDF 解析和范围 | 同版本 PDFium 字形、页序、保守双栏、连续范围、文件内容指纹及行级区域。文件变动、歧义或不可靠布局会拦截 | 17 项合成文档检查使用 Mac 的同版 PDFium。静态核对 Windows x64 DLL 的函数导出。Windows DLL 运行、真实多版式论文及渲染未实测 |
| OCR、图表、公式及证据补读 | Markdown 中的公式显示复用 KaTeX。缺少可靠文字证据的原图、编号公式或扫描页会说明缺口 | Windows OCR、原图和编号公式对象索引、变量定义、模型辅助分段与裁图发送尚未移植 |
| 证据详情和回跳 | 核对实际发送哈希、原文件版本、页码和行位置。可打开本地原页并高亮，旧回答用持久化收据回看 | Windows 原页窗口、坐标、浏览器标签页复用未验收。缺失收据的历史消息不标为已核验 |
| 历史及草稿 | 共享历史搜索、归档筛选、会话读取、草稿与窗口选项 | Windows 主机测试未执行。桌面收藏、归档写入、永久删除及跨启动的附件恢复未对等 |
| 笔记 | 原文复制、公式 LaTeX、回答选段、带补充保存、原文出处 Markdown，不导出内部路径字段 | Windows 对话框、文件覆盖与资源管理器回跳未实测。本地笔记目录和全部 macOS 书签机制未移植 |
| 安装与升级 | 当前用户安装，负载为 Windows x64，自包含 .NET，WebView2 Evergreen 另行提供 | NSIS 安装器已交叉构建，已核对校验和及 x64 应用负载。安装、覆盖升级、卸载、SmartScreen 和真实运行均需 Windows 实测 |

## 已执行检查

- 公共科研桥 TypeScript 构建及 85 项 Node 回归，含 Windows 管道认证和跨通道重放拒绝。Zotero 只读扩展另有 20 项通过。
- Windows WPF 与独立选区、传输代码交叉编译。在 macOS 使用正式 DSH 0.2.2-rc.5 的隔离 HOME 验证了重建桥安装、旧 Unix socket、合成会话持久化和旧工作区身份。没有使用真实模型和用户资料。
- NSIS 安装器使用 LZMA 压缩，Win32 引导程序内装独立的 x64 应用、PDFium、WebView2 Loader 与相应运行时。未签名。实测 56,317,572 字节，SHA‑256 为 3bf09af13d79ef5aa1756be4f645372ed446def8d6857affae8446cedc82fcc6。
- PDF 逻辑 17 项复验覆盖双栏顺序、跨页原句、基本检索、重复锚点和扫描拒绝，以及旋转原页区域与同长度内容变更。Windows PDFium DLL 静态导出表包含全部 24 项所用入口。

## Windows 复验要点

在干净的 Windows 11 x64 配置安装候选包，记录版本与 SHA‑256。在声明通过前须实际核对前三段“取词与文档”的每条路径，并验证正常卸载只移除程序。逐字比较每种阅读器的中英文、Unicode、跨段、无选区和复制竞争。用公开或合成 PDF 检查原文首尾、图表和公式，留存真实来源回跳和笔记文件。从官方 DSH 安装桥，先用隔离会话验证工作区归属和模型，待明确授权后才调用真实模型。区分应用请求准备、首段可见及完整显示。与 macOS v0.3.4 使用同一题和材料，未通过的项须列为缺口。

## 架构依据

原 SwiftUI、AppKit、PDFKit、Vision 和 WebKit API 实现无法在 Windows 直接运行。WPF 保留系统标题栏、可达性、对话框、任务栏和托盘，WebView2 仅加载随包的本地渲染资源。复用 Git 同一主线的桥、样式、许可、图标和 PDFium 版本。平台专有的 PDF、选区和窗口适配集中在 windows 文件夹。Windows 和 macOS 继续各自打包。

## 构建复验

在仓库根目录使用 .NET SDK 10.0.404、带 Pillow 11.3.0 的 Python、NSIS 3.13 和 Node/pnpm。若 NSIS 在独立目录，需按该分发的说明设置 NSISDIR。为构建进程设置独立的 DOTNET_CLI_HOME 和 NUGET_PACKAGES，关闭开发证书自动生成。

    dotnet restore windows/ResearchCompanion.Windows/ResearchCompanion.Windows.csproj \
        --locked-mode -r win-x64 -p:SelfContained=true

在临时目录以发布脚本的 build_bridge 函数生成公开科研桥。参数依次为已存在的临时构建目录、已存在的归档输出目录、是否使用 pnpm 离线缓存以及隔离运行测试的环境。该函数会重建桥并运行协议测试。任何本机订阅适配文件都不属于构建输入。Windows PDFium 使用上游 8165 的 pdfium-win-x64.tgz，构建脚本内固定其 SHA‑256。随后将团队构建工具和实际归档路径代入如下命令。

    python3 windows/build.py \
        --dotnet /path/to/dotnet --makensis /path/to/makensis \
        --nuget-cache /path/to/nuget/packages \
        --pdfium-archive /path/to/pdfium-win-x64.tgz \
        --bridge-archive /path/to/dsh-research-companion-0.2.6.tgz \
        --output /path/to/new/windows-output

PDF 检查程序不依赖 WPF，可在 macOS 用同版本的本机 libpdfium.dylib 复跑，也可在 Windows 用候选包里的 pdfium.dll 单独复跑。

    dotnet run --project windows/tests/PdfEvidence/PdfEvidenceChecks.csproj -- /path/to/pdfium.dll

[固定 PDFium 上游发行](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F8165) · [NSIS 跨平台构建说明](https://nsis.sourceforge.io/Docs/AppendixG.html)
