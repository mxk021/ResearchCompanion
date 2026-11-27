科研助手 Zotero 只读上下文桥 0.1.7

使用

在 Zotero 主窗口的阅读器标签页划选正文，然后在科研助手点击「选取文字」。核对预览后，在输入框提出翻译或解释要求。提交问题时使用本轮会话所选模型。若没有活动选区，请在同一阅读器重新选字。

扩展仅在收到已认证请求时读取活动标签页。实时取词检查 Zotero 主窗口、活动阅读器和阅读器焦点。选区上限为 24,000 个 UTF-16 字符，超出时会提示缩短。选区随附已核验的附件标识及可用的 PDF 文件页，来源入口通过 Zotero 打开相应附件和页。支持范围为主窗口的阅读器标签页。

安装和升级

在此目录执行 python3 build.py 生成 research-companion-context-0.1.7.xpi。
在 Zotero「工具 → 插件」的工具菜单选择“Install Plugin From File…”并选择该文件。核对扩展名称 Research Companion — Read-only Context Bridge、版本和启用状态。仅覆盖 profile 内的 XPI 有可能继续运行旧版。
测试命令为 node --test tests/bridge.test.cjs。
使用带文本层的合成 PDF 运行 python3 tests/check-native-reader.py <合成 PDF>，可在独立离线的 Zotero profile 中检查配对的正式接口、阅读器选区和页码回跳。Windows 上用 python 并加 --zotero <Zotero 可执行文件路径>。

配对和接口

首次启动生成 256 位随机密钥，保存在 Zotero profile 的 dsh-companion-bridge/pairing.json。目录权限是 0700，文件是 0600。读取前检查所有者所用配对文件的类型，拒绝符号链接。扩展不启用 Zotero 全局 Local API，不修改文献、批注或笔记，也不调用模型。

唯一注册的端点为 GET /dsh-companion/context。普通模式可选 fulltext=1，该模式最多读取当前附件已有全文缓存的 512,000 字节。实时取词使用 selection=live&requestId=<UUID>，响应回显该请求号。没有选区或超过上限时，端点返回相应的错误。新版 macOS 与 Windows 客户端可用 X-Research-Companion-Local-PDF: 1 明确请求当前 PDF 的本机路径及文件版本。路径只在认证的活动阅读器取词响应中返回，不经模型或其他外部服务。缺少本机文件时仍保留已取得的选区。

认证头为 Authorization: Bearer <timestampMs>.<32位十六进制nonce>.<64位十六进制HMAC>。HMAC-SHA256 的键为配对 token 的 UTF-8 字节，消息为时间戳、小数点和 nonce。服务验证本机 Host、端口和一分钟内的单次证明，拒绝携带 Origin 的请求。响应禁止缓存，调试日志的响应过滤器隐藏论文原文。
错误包括 FORBIDDEN、INVALID_QUERY、NO_ACTIVE_PAPER、PAPER_CHANGED、SOURCE_CHANGED、NO_SELECTION、UNSUPPORTED 和 SELECTION_TOO_LARGE。

停用与诊断

在 Zotero 插件管理器停用或移除该扩展会注销端点。配对文件保留供重新启用。需要轮换密钥时，先停用扩展，再移走专用的 dsh-companion-bridge 目录。扩展 ID 为 research-companion-context@local.invalid。
Zotero「运行 JavaScript」可用 JSON.stringify(Zotero.ResearchCompanionContextBridgeStatus) 查看版本和启动阶段。该诊断不读取论文和密钥。
Zotero 10 manifest 需要 update_url。本地固定地址 https://127.0.0.1:23119/dsh-companion/updates.json 用于满足该字段。更新通过项目构建并从管理器安装，不放宽系统更新的证书检查。
