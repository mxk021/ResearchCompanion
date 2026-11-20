# 构建与发布

在 Git 的干净检出目录运行以下命令。需要 macOS、完整 Xcode（含 SwiftPM、XCTest 和当前 macOS SDK）、Python 3.9 或更新版本、Node 24.15 或更新版本及 pnpm。本次桥接构建使用 Node 24.22.3、pnpm 11.25.0 与 `pnpm-lock.yaml`。首次安装锁定依赖需要访问 npm。构建与测试不需要 DSH 登录或模型额度。

```sh
python3 scripts/release.py --tag v0.2.9
(cd dist && shasum -a 256 -c *.sha256)
```

`release.json` 管理 App 版本、构建号、bundle ID、最低系统版本。科研桥和可选 Zotero 扩展独立维护各自的协议版本。构建当前 CPU 架构的 DMG，根据架构单独验证；当前安装包为 arm64。每次输出到空目标，可用 `--output` 指定其他目录。已有本地 pnpm 缓存的维护者可用 `--offline`。

构建在临时目录编译科研桥和 App，运行 Swift、WebKit、PDF、桥协议和 Zotero 测试，检查 App 签名及架构，实际只读挂载并核对安装盘，再生成 SHA-256。运行 AppKit/WebKit 测试需要可用的 macOS 图形登录会话。没有完整 Xcode 的维护机可用 `--clt-only` 完成草稿构建；该选项明确跳过 XCTest。可用 `SDKROOT` 指定已安装且与编译器匹配的 SDK。这些步骤不向 `/Applications` 安装，不访问个人 DSH 配置或调用任何模型。

`Resources/PublicManifest.txt` 逐项列举允许分发的资源。公开包只附这份清单中的资源、构建出来的原创图标、许可、入门说明和当前源码构建的科研桥。个人桌宠素材只用于本机维护。DMG 顶层另有可选的 Zotero 扩展。构建会拒绝重复清单项、意外文件、符号链接及带有构建者 HOME 路径的产物。

已装 DSH Desktop 0.2.2-rc.5 的维护者还可在只读挂载 DMG 后使用同一发行包的组件运行端到端复验。将 `app` 设为实际挂载包的路径，若科研桥版本有变化，一并调整包名。此检查新建临时 HOME、profile 和工作区，运行真实 DSH 服务与合成会话，并检查重启恢复。不会复用本机订阅授权。

```sh
app='/Volumes/Research Companion/Research Companion.app'
ELECTRON_RUN_AS_NODE=1 '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness' \
  --expose-internals scripts/check-first-install.mjs \
  "$app/Contents/Resources/dsh-research-companion-0.2.3.tgz" "$app/Contents/MacOS/ResearchCompanion"
```

## 受信任分发

常规 CI 只做 ad-hoc 构建和校验，没有发布权限。公开稳定版需在发行者控制的 Mac 上使用有效的 Developer ID Application 证书和钥匙串中的公证凭据。先使用 `xcrun notarytool store-credentials` 的交互流程录入；密码、私钥及钥匙串均留在发行机。

```sh
python3 scripts/release.py --tag v0.2.9 \
  --identity 'Developer ID Application: Your Organization (TEAMID)' \
  --notary-profile research-companion-notary
```

脚本启用 Hardened Runtime 和安全时间戳，签名 App 与 DMG；仅在显式提供 `--notary-profile` 时向 Apple 提交 DMG，收到 `Accepted` 后装订并验证票据，检查 Gatekeeper，再计算最终文件的校验和。公证失败时可通过返回的提交 ID 查询 Apple 诊断。没有证书的 DMG 应停留在受限测试或草稿阶段。公证与信任流程见 [Apple 发行指南](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

发行时将 `v` 开头的版本标签指向实际构建的干净提交，上传 DMG 和对应 `.sha256`，从 Release 重新下载复核签名与摘要。在独立 Mac 用户或虚拟机验证首次安装、授权与模型后再确认发布质量。

### 私有发布草稿

在已授权的私有仓库中，先用 `python3 scripts/audit-source.py --history` 检查暂存区及本地可达提交，用 `git status` 复核实际发布文件。将测试过的提交推到 main，并为同一提交打版本标签。以下命令在标签已推送后创建草稿，不会开放公众下载：

```sh
gh release create v0.2.9 dist/ResearchCompanion-0.2.9-arm64.dmg dist/ResearchCompanion-0.2.9-arm64.dmg.sha256 --draft --verify-tag --title 'Research Companion 0.2.9' --notes-file CHANGELOG.md
```

请从草稿重新下载两个附件，在一个空目录核对 SHA-256，再从只读挂载的镜像检查应用签名。只有独立安装、授权、许可与签名均已验收，才将仓库和 Release 公开。
