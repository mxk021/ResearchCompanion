import SwiftUI

struct ResearchModelPicker: View {
    @ObservedObject var command: DSHPetCommandClient
    @State private var showingModels = false

    private var selected: ResearchModelSelection? { command.selectedResearchModel }
    private var selectedModel: ResearchModelCatalog.Model? { command.modelCatalog?.model(for: selected) }

    private var title: String {
        if command.modelSwitching { return "切换模型中…" }
        if let selected { return selectedModel?.name ?? selected.model }
        return command.conversationModel ?? (command.modelSelectionAvailable ? "选择模型" : "等待模型目录")
    }

    private var effort: String? {
        guard let selected, let model = selectedModel else { return nil }
        guard let reasoning = model.reasoning, !reasoning.efforts.isEmpty else { return "不可调" }
        let id = selected.reasoningEffort ?? reasoning.defaultEffort
        return reasoning.efforts.first { $0.id == id }?.name ?? id ?? "默认"
    }

    var body: some View {
        Button {
            showingModels = true
            command.refreshModelCatalog()
        } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1).truncationMode(.tail)
                if let effort {
                    Text(effort).foregroundStyle(.secondary).lineLimit(1)
                }
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("research.modelPicker")
        .accessibilityLabel("模型 " + title + (effort.map { "，推理强度 " + $0 } ?? ""))
        .popover(isPresented: $showingModels, arrowEdge: .bottom) { modelPanel }
    }

    private var modelPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("会话模型").font(.headline)
                Spacer()
                Button("刷新") { command.refreshModelCatalog() }
                    .disabled(!command.modelSelectionAvailable || command.modelCatalogLoading)
            }
            if !command.modelSelectionAvailable {
                Text("当前科研桥无法读取模型目录。").foregroundStyle(.secondary)
            } else if let issue = command.modelCatalogError {
                Text(issue).foregroundStyle(.secondary)
            } else if command.modelCatalog == nil || command.modelCatalogLoading {
                ProgressView().controlSize(.small).accessibilityLabel("正在读取可用模型")
            }
            if let selectionError = command.modelSwitchError {
                Text(selectionError).foregroundStyle(.red)
            } else if command.conversationRunning {
                Text("正在生成，结束后可切换。").foregroundStyle(.secondary)
            } else if let selected, command.modelCatalog != nil, selectedModel == nil {
                Text(selected.model + " 当前不可用，请选择可用模型。").foregroundStyle(.secondary)
            }
            if let selected, let reasoning = selectedModel?.reasoning, !reasoning.efforts.isEmpty {
                HStack {
                    Text("推理强度")
                    Spacer()
                    Menu(effort ?? "默认") {
                        ForEach(reasoning.efforts) { level in
                            Button {
                                command.selectResearchModel(.init(provider: selected.provider, model: selected.model, reasoningEffort: level.id))
                            } label: {
                                if (selected.reasoningEffort ?? reasoning.defaultEffort) == level.id {
                                    Label(level.name, systemImage: "checkmark")
                                } else { Text(level.name) }
                            }
                        }
                    }
                    .accessibilityIdentifier("research.reasoningPicker")
                    .disabled(!command.canSelectResearchModel || command.modelCatalogLoading)
                }
            } else if selectedModel != nil {
                Text("推理强度不可调").foregroundStyle(.secondary)
            }
            if let directory = command.modelCatalog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(directory.groups) { group in
                            Text(group.name).font(.subheadline.weight(.semibold)).padding(.top, 4)
                            if let error = group.error {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(group.models) { model in
                                let active = selected?.provider == group.id && selected?.model == model.id
                                Button {
                                    if active, let selected { command.selectResearchModel(selected); return }
                                    command.selectResearchModel(.init(provider: group.id, model: model.id, reasoningEffort: model.reasoning?.defaultEffort))
                                } label: {
                                    HStack {
                                        Text(model.name).lineLimit(1)
                                        Spacer(minLength: 8)
                                        if active { Image(systemName: "checkmark") }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                                .accessibilityIdentifier("research.model.\(group.id).\(model.id)")
                                .disabled(!command.canSelectResearchModel || command.modelCatalogLoading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(14)
        .frame(width: 282, alignment: .leading)
    }
}
