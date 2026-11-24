import SwiftUI

/// Compares the proposed reading order with the same fingerprinted PDF used for indexing.
struct ResearchPDFReviewView: View {
    let review: DSHPetCommandClient.PDFLayoutReview
    let finish: (Bool) -> Void
    @State private var preview: ResearchPDFEvidenceReader.Prepared?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("核对原文顺序").font(.headline)
            Text(review.evidence.reason).font(.callout).textSelection(.enabled)
            HSplitView {
                Group {
                    if let preview {
                        PDFComparisonPage(prepared: preview)
                    } else if let failure {
                        Text(failure).foregroundStyle(.secondary).padding()
                    } else {
                        ProgressView("正在打开原页…")
                    }
                }.frame(minWidth: 255, maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("候选原文 · 按拟发送顺序").font(.caption).foregroundStyle(.secondary)
                        ForEach(review.evidence.materials.indices, id: \.self) { offset in
                            let part = review.evidence.materials[offset]
                            Text(part.text).font(.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(8)
                }.frame(minWidth: 190)
            }
            HStack {
                Button("取消，保留问题") { finish(false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("顺序正确，继续") { finish(true) }.disabled(preview == nil)
            }
        }
        .padding(14)
        .frame(minWidth: 530, idealWidth: 770, maxWidth: .infinity, minHeight: 350, idealHeight: 530, maxHeight: .infinity)
        .task(id: review.id) {
            let worker = Task.detached(priority: .userInitiated) { [review] in
                guard let (url, bytes) = review.reference.verifiedPDF(),
                      let page = review.evidence.pages.first else {
                    throw ResearchMaterialError.message("原文件已变化或无法读取。请取消后重新关联。")
                }
                let positions = review.evidence.materials.flatMap { $0.pdfPositions ?? [] }
                // Show the uncertain region first, then allow navigation through the entire candidate.
                let marked = Set(review.evidence.pages)
                let ordered = positions.filter { marked.contains($0.page) } + positions.filter { !marked.contains($0.page) }
                return try ResearchPDFEvidenceReader.prepare(data: bytes, filename: url.lastPathComponent,
                                                            positions: ordered, firstPage: page, requireMappedPositions: true)
            }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                preview = value
            } catch is CancellationError { return }
            catch { failure = error.localizedDescription }
        }
    }
}

private struct PDFComparisonPage: NSViewControllerRepresentable {
    let prepared: ResearchPDFEvidenceReader.Prepared
    func makeNSViewController(context: Context) -> ResearchPDFEvidenceReader {
        ResearchPDFEvidenceReader(prepared, showsClose: false)
    }
    func updateNSViewController(_ controller: ResearchPDFEvidenceReader, context: Context) {}
}
