# Research Companion Windows 候选版

此候选版来自 `windows/port-v0.3.4` 分支，以 macOS v0.3.4 为基线。当前 Windows 候选为 0.3.4.2。安装文件名、程序版本和卸载注册版本使用同一版本号。实机结果见 [验收报告](VERIFICATION.md)。

## 在测试机安装

使用 Windows 11 x64 测试机或隔离虚拟机，预先确认 Microsoft Edge WebView2 Evergreen Runtime 可用。安装程序为当前用户安装自带 .NET 运行时的 x64 应用，写入 %LOCALAPPDATA%\Programs\Research Companion 并创建开始菜单快捷方式。候选安装程序未经 Authenticode 签名，系统或组织策略可能拦截。

在 PowerShell 用 Get-FileHash 检查候选 EXE，并与同名 .sha256 比较。接受来源、摘要和测试机策略后再安装。升级或卸载前，从系统托盘退出应用。卸载保留 %LOCALAPPDATA%\ResearchCompanion 的草稿和本机来源记录，不卸载 DSH 或 Zotero。

WebView2 缺失时，从 Microsoft 官方渠道安装 Evergreen Runtime。候选安装程序不自动联网安装它。[Microsoft WebView2 下载](https://developer.microsoft.com/microsoft-edge/webview2/)

## 连接科研桥

1. 另行安装官方 Windows x64 DSH Desktop，打开一次初始化桌面 profile，然后从程序菜单完全退出。
2. 将科研助手安装目录 `app` 中的 `dsh-research-companion-0.2.6.tgz` 复制到独立的用户目录。DSH 的本地包依赖会继续使用这份归档。用 DSH 自带的 `dsh.cmd` 在 PowerShell 执行下列命令，并使用复制后的绝对路径。

       dsh plugin --profile desktop add --offline --ignore-scripts "file:C:\path\to\dsh-research-companion-0.2.6.tgz"

3. 打开 DSH，再点科研助手的「连接 DSH」。科研助手使用桥提供的科研工作区和为本次会话选择的账号模型。公开包不包含订阅适配器、API Key 或用户账号。

[DSH 官方下载](https://www.deepseek.com/download/) · [上游桌面构建说明](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/README.md)

## 取词与文档

- 「选取文字」优先使用 UI Automation，Zotero 配对后可读取活动阅读器。经用户允许，支持的应用可原生复制。这可能覆盖剪贴板，应用不恢复原内容。直接读和原生复制均不可用时，可手动复制并粘贴。普通浏览器 UIA 取词不附加未经验证的网址。
- 可从 `app` 文件夹取出 `research-companion-context-0.1.6.xpi`，在 Zotero 10 从文件安装并重启。扩展提供经过配对的只读选区。已核验的 Zotero 回答在原配对阅读器运行时可打开同一附件页。旧来源仍可查看摘录，缺少配置标识的旧链接可通过重新取词绑定。
- 文件支持 PDF、TXT、Markdown。按需要求页段、原句范围或关键词摘录。使用「识别扫描页」调用 Windows 已安装语言的本机 OCR，并用「预览原页」核对。指定单个图、表或公式编号时，应用查找唯一题注或公式，并将有界区域裁图带入支持图像的模型。复杂版式和 OCR 文本应在原页复核。只有桥返回本次原文哈希且模型身份一致时，应用才把材料记录为已核验发送。
- 可使用托盘唤回、可选置顶和外观菜单。系统未占用时，Ctrl+Alt+T 打开取词预览。Markdown 笔记通过系统保存对话框选择路径。
- 使用非默认 Zotero 10 配置时，可在托盘的「Zotero 配对…」选择该配置中的 `dsh-companion-bridge/pairing.json`。扩展和应用通过本机回环配对。
- 重开同一会话时，应用会核对原本关联的本机文件指纹，再恢复材料和 OCR 设置。文件变更时可重新选择。账号模型按该会话的选用确认恢复。从旧候选版首次打开已有会话时，需要重新选择附件和账号模型一次。

## 构建

使用 .NET SDK 10.0.404、Python 3.9+、构建期 Pillow 11.3.0、NSIS 3.13，以及与 Apple 版同一铬内核构建号 8165 的 PDFium。交叉构建支持从 ARM64 macOS 生成 Windows x64 应用和 NSIS 安装包，运行时验收需要 Windows。NuGet WebView2 版本和哈希见项目锁文件。macOS 应用构建仍走原有脚本。

在隔离目录中使用仓库的 pnpm 锁文件，运行 `pnpm build`，然后运行 `python -X utf8 scripts/package-bridge.py --windows --public --output <归档路径>`。Windows 归档包含构建器生成的 JavaScript 分块。将构建的 .tgz 路径传给 Windows 安装包构建工具。准确的复验命令见 [验收报告](VERIFICATION.md)。

[WPF 交叉目标设置](https://learn.microsoft.com/en-us/dotnet/core/tools/sdk-errors/netsdk1100) · [WebView2 Runtime 分发](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)
