# 安装和首次使用

需要 Apple 芯片 Mac、macOS 14 或更新版本。打开 DMG，把 Research Companion 拖进“应用程序”，从那里启动。以 Release 页面标明的签名和公证状态为准。若组织策略或 Gatekeeper 不允许该构建，请等待受信任的发行版。

## 连接本机的 DSH

1. 安装并启动官方 DeepSeek Harness Desktop。此次验证的精确版本为 **0.2.2-rc.5**，应用标识为 `com.deepseek.dsh`。首次打开后等主窗口初始化，从 DSH 应用菜单正常退出。新版本及其他同名桌面客户端需要另行适配。若官方只提供不同版本，请保留原安装，等候兼容版本。[DeepSeek 官方下载](https://www.deepseek.com/harness/)
2. 打开科研助手，点聊天面板底部的 **连接设置**。点 **安装科研桥** 会用该版 DSH 自带的 CLI，将应用内的桥接包离线加入当前用户的 `desktop` profile。安装目标为默认的 `~/.dsh`。请在安装结束前保持 DSH 退出。已有桥接或使用自定义 profile 的用户可直接检查 DSH 的插件页及原有连接。
3. 点 **打开 DSH**，保持 DSH 运行，回到科研助手等待连接。科研桥会自动注册专用工作区。新安装的位置为 `~/Library/Application Support/Research Companion/Workspace`。已有版本在 DSH 中注册的旧科研工作区继续使用原路径。
4. 在 DSH 中配置你自己的模型账户，然后在科研助手聊天面板上方点 **选择模型** 或当前模型名，刷新目录并选择。DeepSeek 账户模型可能按账户余额计费，请先了解所选模型的价格。ChatGPT 订阅需要用户已经具备兼容的独立 DSH 提供方并完成自己的授权。发行包没有提供该适配器、订阅或 API Key。目录可以直接显示某一路线未接入、尚未登录或无可用模型。未选择可用路线时，选区翻译会停在本机提示。
5. 选择文本、Markdown 或带文本层的 PDF，检查当前材料和读取范围，输入问题并发送。点击“选取文字”只在面板预览本次选区；发送问题时才会将带入的材料交给所选模型。翻译快捷键或“翻译选区”服务会直接提交本次选区。仅打开面板不会提交材料。

## 可选的系统权限和 Zotero

通过 **设置 → 快捷键** 查看本机实际快捷键。直接读取其他应用选区需在 macOS **系统设置 → 隐私与安全性 → 辅助功能** 允许安装在 Applications 的这份科研助手。Safari、预览以及不同应用所暴露的选区各有差异；提供系统“服务”的应用也可直接调用“翻译选区”。文件问答可在不授予跨应用选区权限的情况下使用。

如需读取 Zotero 主窗口当前阅读器选区，使用 Zotero 10，在 **工具 → 插件 → 齿轮 → 从文件安装插件** 选择 DMG 中的 `research-companion-context-0.1.4.xpi`。首次运行会为该 Zotero profile 生成仅限本机的配对密钥。打开论文并在阅读器选中文字后触发翻译。独立弹出的阅读器窗口尚未验证。未安装 Zotero 时仍可使用其他来源。[Zotero 下载](https://www.zotero.org/download/)

## 连接及数据

- **找不到 DSH**。核对下载来源、应用名及版本。只有在确认兼容的官方签名后才会执行随 DSH 安装的插件管理命令。
- **桥已登记，仍未连接**。打开 DSH，在插件列表确认 `dsh-research-companion` 加载成功。若安装中断，先查看 DSH 的插件诊断，再重新检查。应用保留科研桥离线包在 `~/.dsh/local-plugins/ResearchCompanion/`；DSH 的 `file:` 依赖存续期间请保留这个目录。若 profile 已有第三方依赖且离线缓存不完整，安装可能失败，请先修复原 profile。
- **模型目录或额度**。提供方维护模型列表、可用推理档及账户费用。科研助手使用 DSH 当前用户的授权。聊天和材料会随发送交给选中提供方并在本机 DSH 会话中保存。请勿把 profile、配对文件及诊断中的私密信息提交到 GitHub。
- **会话管理**。新安装的标准 DSH 提供历史、检索及归档。永久删除需要经过验证的专用存储维护组件；此发行包不会安装该组件。没有该能力的主机会保持永久删除不可用。已导出的 Markdown 笔记独立于会话。
- **移除桥接**。先从 DSH 菜单正常退出，再在终端执行下列 DSH 自带命令。移除插件不会主动清理既有 DSH 会话、论文或用户笔记。

```sh
"/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh" plugin --profile desktop remove dsh-research-companion
```
