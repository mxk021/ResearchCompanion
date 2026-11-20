import Foundation

/// Resolve the two local material sources before preparing evidence or admitting a model request.
enum ResearchDocumentScope {
    case general, selection, file, combined

    static func resolve(question: String, mode: ResearchPromptMode, selection: ResearchMaterial?,
                        hasFile: Bool, filename: String?, captureFailed: Bool) throws -> Self {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        func mentions(_ pattern: String) -> Bool {
            q.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let pointsToSelection = mentions(#"选区|选中|所选|划选|划线|高亮|这(?:一)?(?:段|句)|\b(?:selection|highlight(?:ed)?|selected (?:text|passage)|this (?:passage|sentence|excerpt))\b"#)
        let excludesFile = mentions(#"(?:不要|不必|忽略|不参考|不结合)[^，。；,;]{0,8}(?:文件|论文|PDF)|(?:只|仅)(?:需|要)?(?:翻译|看|解释|分析|使用|处理)?(?:当前|本次)?(?:选区|所选|这一句)|\b(?:selection only|only (?:the )?select(?:ion|ed text)|ignore the (?:paper|file))\b"#)
        let excludesSelection = mentions(#"(?:忽略|不要|不使用|不参考)(?:当前|本次)?(?:选区|所选文字)|ignore (?:the )?selection"#)
        let namesFile = ResearchMaterial.requestsFileBackground(q, filename: filename)
            || mentions(#"(?:论文|本文|这篇|文章|文中|作者|研究方法|PDF|附件|整篇|全文)|\b(?:paper|document|authors?|manuscript|appendix|abstract)\b"#)
            || ResearchPDFIndex.requestsLocation(q)
        if !excludesFile, case .anchors = ResearchPDFAddress.parse(q) {
            guard hasFile else { throw ResearchMaterialError.message("请先选择要定位起止原句的文件。") }
            return .file
        }
        let asksForBackground = ResearchMaterial.requestsFileBackground(q, filename: filename)
            || mentions(#"(?:结合|对照|根据|参考|比较|联系).{0,18}(?:论文|文中|文件|本文|文献|原文)|(?:这段|这句|选区).{0,12}在(?:文中|论文中|文章中)|(?:in (?:the )?context of|in light of|compare.{0,18}(?:paper|document))"#)
        let explicitSelection = mentions(#"选区|选中|所选|高亮|\b(?:selection|selected|highlighted)\b"#)
        if pointsToSelection && !excludesSelection && asksForBackground && !excludesFile {
            guard hasFile else { throw ResearchMaterialError.message("请先选择要与本次选区对照的文件。") }
            guard selection != nil else { throw ResearchMaterialError.message("本次未取得选区，无法与论文对照。") }
            return .combined
        }
        if excludesFile || (pointsToSelection && !excludesSelection && (explicitSelection || selection != nil || !hasFile)) {
            guard selection != nil else { throw ResearchMaterialError.message("本次未取得选区。请重新选中文字。") }
            return .selection
        }
        if namesFile || excludesSelection {
            guard hasFile else {
                if ResearchPDFIndex.requestsLocation(q) || excludesSelection {
                    throw ResearchMaterialError.message("当前未关联会话文件。请选择原文件再定位。")
                }
                return selection == nil ? .general : .selection
            }
            return .file
        }
        if captureFailed { throw ResearchMaterialError.message("本次未取得选区。请重新选取，或在问题中指明使用会话文件。") }
        guard let selection else { return hasFile ? .file : .general }
        guard hasFile else { return .selection }
        if mode != .ask || q.isEmpty { return .selection }
        let overlap = ResearchPDFIndex.searchTerms(q).intersection(ResearchPDFIndex.searchTerms(String(selection.text.prefix(1_200))))
        if !overlap.isEmpty { return .selection }
        throw ResearchMaterialError.message("同时有选区和会话文件。请在问题中注明“选区”“论文”，或说“结合论文解释这段”。")
    }
}
