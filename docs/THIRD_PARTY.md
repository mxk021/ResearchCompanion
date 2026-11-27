# 第三方来源与发行范围

Research Companion 是独立的 macOS 和 Windows 软件。项目自身可授权的新增代码、原创应用图标和公开版「书签」桌宠采用仓库根目录的 MIT 许可证。第三方文件保留各自的许可和署名。

## 随软件分发

| 内容 | 来源、许可及处理 |
| --- | --- |
| 原生桌宠窗口、动画协议、设置与科研桥的上游基础 | sundusk 的 DSH Pet v0.9.5，固定提交 `e5df49ae17008e1533cfd1bccbc67e22378dab77`，MIT。上游和本项目的修改均保留声明。[上游版本](https://github.com/sundusk/dsh-mac-pet/tree/e5df49ae17008e1533cfd1bccbc67e22378dab77) · [许可证副本](../Resources/LicenseNotices/dsh-mac-pet-MIT.txt) |
| KaTeX 0.19.1 的 JavaScript 和 CSS | 原样提供 npm 发布物中的指定文件，MIT。[上游版本](https://github.com/KaTeX/KaTeX/tree/v0.19.1) · [许可证](../Resources/Transcript/vendor/katex/LICENSE) |
| KaTeX 数学字体 | TTF、WOFF 和 WOFF2 均为未经修改的原版。字体内嵌声明指明 Design Science 与 Khan Academy、SIL OFL 1.1 和各自保留的字体名称；字体单列许可。[字体来源](https://github.com/KaTeX/KaTeX/tree/v0.19.1/fonts) · [字体声明与 OFL 全文](../Resources/LicenseNotices/KaTeX-fonts-OFL.txt) |
| markdown-it 15.0.3 浏览器构建 | MIT。随浏览器分发物保留 mdurl、entities、uc.micro、linkify-it 和 punycode.js 的通知，包括 entities 的 BSD-2-Clause。命令行解析器 argparse 和 KaTeX 命令行使用的 commander 均不作为应用运行组件打包。[上游版本](https://github.com/markdown-it/markdown-it/tree/15.0.3) · [主许可证](../Resources/Transcript/vendor/markdown-it/LICENSE) · [库内依赖声明](../Resources/LicenseNotices/markdown-it-dependencies.txt) |
| PDFium 160.0.8165.0 | 两个平台分别使用固定架构及 SHA-256 的归档。PDFium 主体采用 BSD-3-Clause。分发器 MIT 声明和归档的第三方许可随包放在 `LicenseNotices/PDFium`。macOS 结合 PDFKit 提取，Windows 使用 PDFium 读取和渲染。[固定发布档](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F8165) · [PDFium 许可证](https://pdfium.googlesource.com/pdfium/+/refs/heads/main/LICENSE) |
| Windows .NET 运行时和 WebView2 SDK | x64 安装包携带锁定的 .NET 运行时与 WebView2 SDK 加载器。打包器从对应 NuGet 包复制许可证和第三方声明至 `LicenseNotices`。WebView2 Evergreen 浏览器运行时由系统提供或单独安装。[Windows 构建说明](../windows/README.md#构建) |
| Zotero 只读选区扩展 | 独立扩展，使用 Zotero 插件与阅读器 API。扩展自身由本项目源码构建。Zotero 程序、数据库、配对文件及插件授权由使用者自己管理。[扩展源码](../zotero-context-bridge/) · [Zotero 插件文档](https://www.zotero.org/support/dev/zotero_7_for_developers) |

公开桌宠的轮廓、眼睛、书签和动作由 SwiftUI 几何图形直接绘制。公开包排除维护者环境中的所有角色图集、导入宠物和私人截图，原作者许可及角色权利未经独立确认的美术文件不进入版本历史。README 里的示例仅在离屏 WKWebView 加载本项目真实的对话界面，内容为合成的单摆练习。[桌宠绘制](../Sources/DSHPet/BookmarkPetArt.swift) · [图标母版](../Resources/AppIcon.png) · [截图生成](../scripts/render-public-screenshot.swift)

macOS 选区程序使用 AppKit、Accessibility 与 Services。Windows 使用系统 UI Automation。macOS 的设计曾参考 SelectedTextKit 的取词思路，并比较 Easydict 的选区流程。项目独立实现并保留 SelectedTextKit 的 MIT 通知。Easydict 采用 GPL-3.0，后续如引入实现代码须重新审查整个分发方案。[SelectedTextKit 固定源码](https://github.com/tisfeng/SelectedTextKit/tree/93dc960a5ef8d52de98af41d4abd7a89576d091c) · [MIT 通知](../Resources/LicenseNotices/SelectedTextKit-MIT.txt) · [Easydict 固定源码](https://github.com/tisfeng/Easydict/tree/1613c54e15fef7e53818ebca2bcd0a50eb86110b)

## 外部依赖

- **DSH Desktop** 提供模型、工作区和会话。用户自行从其官方渠道取得匹配版本。发行包内的科研桥运行时引用宿主提供的 DSH/Cordis 模块；安装镜像不含 DSH Desktop 或用户模型配置。签名、商标及与服务相关的权利由各自权利人管理。[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
- **ChatGPT 订阅接入**是可选外部提供方。ckanner 的 0.1.20 插件源码标示 MIT；服务访问受提供方账号资格、使用条款和当时可用性限制。科研助手不分发本机维护的订阅适配器，也不代用户授予服务访问权。用户须使用自己选择并信任的提供方及自己的凭据。独立安装的上游插件和本机维护版可能有差异。[上游许可证](https://github.com/ckanner/dsh-plugin-chatgpt/blob/v0.1.20/LICENSE) · [安装说明](SETUP.md)
- **macOS 框架与字体**由系统提供。SwiftPM 原生目标无外部 Swift 包。TypeScript、打包器和其他 Node 开发依赖按锁文件安装供构建使用；源码仓库与 App 不包含 node_modules。请从 Zotero 官方渠道获取可选的 Zotero 桌面程序。[Zotero 下载](https://www.zotero.org/download/)

## 核对发行文件

打包器从 `Resources/PublicManifest.txt` 逐项取得公开资源。维护者可以运行 `python3 scripts/vendor-transcript.py --verify`，以固定版本 npm 归档的 SHA-512 比对 JS、CSS、字体及原始许可文件。更新依赖后，还须重新核对字体名称表中的许可、浏览器 bundle 的运行依赖及这些依赖的声明。[公开资源清单](../Resources/PublicManifest.txt) · [固定资源核验](../scripts/vendor-transcript.py)
