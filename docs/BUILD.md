# 构建与发布

在 Git 的干净检出目录运行以下命令。从源码构建 v0.2.11 时先检出该版本标签，开发分支直接运行同一打包脚本即可。需要 macOS、完整 Xcode（含 SwiftPM、XCTest 和当前 macOS SDK）、Python 3.9 或更新版本、Node 24.15 或更新版本及 pnpm。本次桥接构建使用 Node 24.22.3、pnpm 11.25.0 与 `pnpm-lock.yaml`。首次安装锁定依赖需要访问 npm。构建与测试不需要 DSH 登录或模型额度。

```sh
python3 scripts/release.py
(cd dist && shasum -a 256 -c *.sha256)
```

`release.json` 管理 App 版本、构建号、bundle ID、最低系统版本。科研桥和可选 Zotero 扩展独立维护各自的协议版本。构建当前 CPU 架构的 DMG，根据架构单独验证；当前安装包为 arm64。每次输出到空目标，可用 `--output` 指定其他目录。已有本地 pnpm 缓存的维护者可用 `--offline`。

构建在临时目录编译科研桥和 App，运行 Swift、WebKit、PDF、桥协议和 Zotero 测试，检查 App 签名及架构，实际只读挂载并核对安装盘，再生成 SHA-256。运行 AppKit/WebKit 测试需要可用的 macOS 图形登录会话。没有完整 Xcode 的维护机可用 `--clt-only` 构建社区测试包。该选项跳过 XCTest，记录测试结果时请注明。可用 `SDKROOT` 指定已安装且与编译器匹配的 SDK。这些步骤不向 `/Applications` 安装，不访问个人 DSH 配置或调用任何模型。

完整 Xcode 构建沿用 Xcode 管理的 Metal 工具链缓存，使只读挂载独立于测试用的临时 HOME。科研助手的设置和合成会话仍在临时目录。

`Resources/PublicManifest.txt` 逐项列举允许分发的资源。公开包只附这份清单中的资源、构建出来的原创图标、许可、入门说明和当前源码构建的科研桥。个人桌宠素材只用于本机维护。DMG 顶层另有可选的 Zotero 扩展。构建会拒绝重复清单项、意外文件、符号链接及带有构建者 HOME 路径的产物。

已装 DSH Desktop 0.2.2-rc.5 的维护者还可在只读挂载 DMG 后使用同一发行包的组件运行端到端复验。将 `app` 设为实际挂载包的路径。此检查新建临时 HOME、profile 和工作区，运行真实 DSH 服务与合成会话，并检查重启恢复。不会复用本机订阅授权。

```sh
app='/Volumes/Research Companion/Research Companion.app'
bridge_version=$(python3 -c 'import json; print(json.load(open("package.json"))["version"])')
ELECTRON_RUN_AS_NODE=1 '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness' \
  --expose-internals scripts/check-first-install.mjs \
  "$app/Contents/Resources/dsh-research-companion-${bridge_version}.tgz" "$app/Contents/MacOS/ResearchCompanion"
```

如需验证公开版升级，可先按旧版本的 SHA-256 校验 v0.2.10 安装盘，将环境变量 `RC_TEST_UPGRADE_FROM` 指向旧包内的 `dsh-research-companion-0.2.3.tgz`，再执行同一条检查命令。程序在临时 HOME 中先安装旧桥、创建合成会话，正常停服，用正式 CLI 更新到新桥，并验证重启后会话仍在、文档取证能力已出现。

## 发布 Community Beta

v0.2.11（构建 23）以 GitHub **Pre-release** 提供。包内 App 默认采用 ad hoc 签名，未经 Apple 公证。常规 CI 只做构建和校验，发布由维护者在仓库中操作。

1. 核对候选提交、版本标签和构建输入。在审核过的干净检出目录运行 `python3 scripts/audit-source.py --history`，检查暂存区与本地引用可达的提交。另行复核截图、第三方声明，以及 GitHub 上的附件、Actions 日志和产物。
2. 核对标签指向实际构建提交，并验证原始镜像。脚本的 `--tag` 只检查版本字符串。已有标签的版本保留原提交和原附件，软件实现变更应更新版本并打新标签。
3. 从对应 Release 下载 DMG 和 `.sha256`，核对摘要，挂载镜像，验证 App 的版本、架构、签名和安装内容。发行说明应分别列出已测试环境、需要自行安装的宿主、账号要求与尚待实机验收的步骤。[v0.2.11 版本记录](../CHANGELOG.md)
4. 在现有 Release 勾选 **Set as a pre-release** 后发布。退出 GitHub 登录或使用无身份凭据的客户端，重新下载这两个附件并验证 SHA-256。[GitHub Releases](https://github.com/mxk021/ResearchCompanion/releases)

## 可选的 Developer ID 签名与 Apple 公证

准备分发公证版本时，在发行者控制的 Mac 上配置 Developer ID Application 证书。使用 `xcrun notarytool store-credentials` 的交互流程将公证凭据保存到钥匙串。随后从目标版本的干净检出目录执行以下命令。

```sh
python3 scripts/release.py \
  --identity 'Developer ID Application: Your Organization (TEAMID)' \
  --notary-profile research-companion-notary
```

此模式启用 Hardened Runtime 和安全时间戳，签名 App 与 DMG，向 Apple 提交 DMG。收到 `Accepted` 后装订并验证公证票据，检查 Gatekeeper，再计算最终文件的校验和。若提交失败，可通过提交 ID 查询 Apple 诊断。[Apple 公证工作流](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
