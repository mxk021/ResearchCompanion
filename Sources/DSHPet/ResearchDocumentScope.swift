import Foundation

/// Explicit source restrictions are decided before any planning request can see a document.
enum ResearchDocumentScope {
    case general, selection, file, combined, automatic

    var usesFile: Bool { self == .file || self == .combined || self == .automatic }

    static func resolve(question: String, mode: ResearchPromptMode, selection: ResearchMaterial?,
                        hasFile: Bool, filename: String?, captureFailed: Bool) throws -> Self {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        func mentions(_ pattern: String) -> Bool {
            q.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let ignoresFile = mentions(#"(?:不要|不用|无需|不必|忽略|不参考|不结合|不看|别看)[^，。；,;]{0,12}(?:文件|论文|文献|文档|全文|PDF)|(?:只|仅)[^，。；,;]{0,10}(?:选区|选中|所选|划选|高亮|这一句)|\b(?:selection only|selected (?:text|passage) only|only (?:the |my )?(?:select(?:ion|ed (?:text|passage))|highlighted text)|(?:ignore|without|do not (?:use|reference)) (?:the )?(?:paper|file|document|pdf))\b"#)
        let ignoresSelection = mentions(#"(?:忽略|不用|不要|不使用|不参考)(?:当前|本次)?(?:选区|所选文字)|\bignore (?:the )?selection\b"#)
        let selectionNamed = mentions(#"选区|选中(?!的?(?:论文|文件|文章|PDF))|所选(?!的?(?:论文|文件|文章|PDF))|划选|高亮|\b(?:selection|highlighted|selected (?:text|passage))\b"#)
        let deictic = mentions(#"这(?:一)?(?:段|句)|\bthis (?:passage|sentence|excerpt)\b"#)
        let combined = mentions(#"(?:结合|对照|根据|参考|比较|联系).{0,18}(?:论文|文中|文件|本文|文献|原文)|(?:这段|这句|选区).{0,12}在(?:文中|论文中|文章中)|\b(?:in (?:the )?context of|in light of|compare.{0,18}(?:paper|document))\b"#)
        if ignoresFile {
            guard selection != nil else { throw ResearchMaterialError.message("本次未取得选区。请重新选中文字。") }
            return .selection
        }
        if hasFile {
            if case .anchors = ResearchPDFAddress.parse(q) { return .file }
            if ignoresSelection { return .file }
            if combined && (selectionNamed || deictic), selection != nil { return .combined }
            let widerScope = mentions(#"下一页|跨页|起点|终点|全文|接下去|接下来|往后|继续到|next page|continue|through"#)
            if q.isEmpty && mode != .ask { return selection == nil ? .file : .selection }
            if ResearchPDFIndex.requestsLocation(q) || !ResearchPDFObjectID.addresses(in: q).isEmpty ||
                ResearchMaterial.requestsFileBackground(q, filename: filename) {
                return .file
            }
            if selection != nil, !widerScope, selectionNamed || deictic { return .selection }
            if selectionNamed, selection == nil, !widerScope, !combined {
                throw ResearchMaterialError.message("本次未取得选区。请重新选中文字。")
            }
            return .automatic
        }
        if selection != nil { return .selection }
        if selectionNamed || ignoresSelection || combined || captureFailed && (deictic || mode != .ask) {
            throw ResearchMaterialError.message(ignoresSelection ? "当前未关联会话文件。" : "本次未取得选区。请重新选中文字。")
        }
        return .general
    }
}
