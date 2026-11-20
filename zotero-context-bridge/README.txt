科研助手 Zotero 只读上下文桥 0.1.4

使用

在 Zotero 主窗口的阅读器标签页划选正文，按科研助手「设置 → 快捷键」中的「翻译选区」。默认组合键为 Control+Option+T。科研助手读取当前选中文字，交给本轮会话所选模型翻译。唤起窗口的快捷键仍可独立设置。

要先查看文字，请在 Zotero 阅读器中选中正文，然后在科研窗点击「选取文字」。核对选区后可在后续提问中使用。若没有活动选区，重新在同一阅读器选字。

扩展仅在收到已认证请求时读取活动标签页，没有选区监听器和选区历史。即时翻译检查 Zotero 主窗口、活动阅读器和阅读器焦点。普通预览和翻译的单次上限均为 24,000 个 UTF-16 字符。普通预览标记截短，即时翻译会提示缩短过长的选区。已有页码和 PDF 页序可用于定位。独立弹出的阅读器窗口不在支持范围内。

安装和升级

在此目录执行 python3 build.py 生成 research-companion-context-0.1.4.xpi。
在 Zotero「工具 → 插件」的工具菜单选择“Install Plugin From File…”并选择该文件。核对扩展名称 Research Companion — Read-only Context Bridge、版本和启用状态。仅覆盖 profile 内的 XPI 有可能继续运行旧版。
测试命令为 node --test tests/bridge.test.cjs。
使用带文本层的合成 PDF 运行 python3 tests/check-native-reader.py <合成 PDF>，可在独立离线的 Zotero profile 中检查配对的正式接口、阅读器选区和清空行为。

配对和接口

首次启动生成 256 位随机密钥，保存在 Zotero profile 的 dsh-companion-bridge/pairing.json。目录权限是 0700，文件是 0600。读取前检查所有者所用配对文件的类型，拒绝符号链接。扩展不启用 Zotero 全局 Local API，不修改文献、批注或笔记，也不调用模型。

唯一注册的端点为 GET /dsh-companion/context。普通模式可选 fulltext=1，该模式最多读取当前附件已有全文缓存的 512,000 字节。即时翻译使用 selection=live&requestId=<UUID>，响应回显该请求号。没有选区或超过上限时不会返回全文或摘要作为译文材料。

认证头为 Authorization: Bearer <timestampMs>.<32位十六进制nonce>.<64位十六进制HMAC>。HMAC-SHA256 的键为配对 token 的 UTF-8 字节，消息为时间戳、小数点和 nonce。服务验证本机 Host、端口和一分钟内的单次证明，拒绝携带 Origin 的请求。响应禁止缓存，调试日志的响应过滤器隐藏论文原文。
错误包括 FORBIDDEN、INVALID_QUERY、NO_ACTIVE_PAPER、PAPER_CHANGED、SOURCE_CHANGED、NO_SELECTION、UNSUPPORTED 和 SELECTION_TOO_LARGE。

停用与诊断

在 Zotero 插件管理器停用或移除该扩展会注销端点。配对文件保留供重新启用。需要轮换密钥时，先停用扩展，再移走专用的 dsh-companion-bridge 目录。扩展 ID 为 research-companion-context@local.invalid。
Zotero「运行 JavaScript」可用 JSON.stringify(Zotero.ResearchCompanionContextBridgeStatus) 查看版本和启动阶段。该诊断不读取论文和密钥。
Zotero 10 manifest 需要 update_url。本地固定地址 https://127.0.0.1:23119/dsh-companion/updates.json 用于满足该字段。更新通过项目构建并从管理器安装，不放宽系统更新的证书检查。
