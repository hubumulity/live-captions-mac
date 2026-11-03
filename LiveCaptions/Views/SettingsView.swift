import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var viewModel: CaptionViewModel

    @State private var apiKeyDraft = ""
    @State private var isKeyVisible = false
    @State private var savedMessage: String?

    var body: some View {
        Form {
            Section("Gemini API") {
                HStack {
                    Group {
                        if isKeyVisible {
                            TextField("API Key", text: $apiKeyDraft)
                        } else {
                            SecureField("API Key", text: $apiKeyDraft)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                    Button {
                        isKeyVisible.toggle()
                    } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isKeyVisible ? "隐藏 API Key" : "显示 API Key")
                }

                HStack {
                    Button("保存到 Keychain") {
                        settings.apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        savedMessage = settings.keychainError ?? "已安全保存"
                    }
                    .disabled(apiKeyDraft.isEmpty)

                    Button("清除", role: .destructive) {
                        apiKeyDraft = ""
                        settings.apiKey = ""
                        savedMessage = "已清除"
                    }

                    if let savedMessage {
                        Text(savedMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("模型", selection: $settings.modelName) {
                    ForEach(GeminiLiveModel.presets, id: \.id) { preset in
                        Text(preset.label).tag(preset.id)
                    }
                    if !GeminiLiveModel.presets.contains(where: { $0.id == settings.modelName }) {
                        Text("自定义：\(settings.modelName)").tag(settings.modelName)
                    }
                }
                .disabled(viewModel.isRunning)

                TextField("自定义模型 ID", text: $settings.modelName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isRunning)

                if GeminiLiveModel.shutDown.contains(settings.modelName) {
                    Text("该模型已被 Google 关停，连接会被拒绝。请选择 \(GeminiLiveModel.recommended)。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Picker("字幕来源", selection: $settings.captionSource) {
                    ForEach(CaptionSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
            }

            Section("实时翻译") {
                Toggle("翻译字幕", isOn: $settings.translationEnabled)
                    .disabled(viewModel.isRunning)

                Picker("目标语言", selection: $settings.targetLanguage) {
                    ForEach(TargetLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(!settings.translationEnabled || viewModel.isRunning)

                Picker("翻译方式", selection: $settings.translationMode) {
                    ForEach(TranslationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(!settings.translationEnabled || viewModel.isRunning)

                switch settings.translationMode {
                case .pipeline:
                    Picker("翻译模型", selection: $settings.translationModel) {
                        ForEach(GeminiTextModel.presets, id: \.id) { preset in
                            Text(preset.label).tag(preset.id)
                        }
                        if !GeminiTextModel.presets.contains(where: { $0.id == settings.translationModel }) {
                            Text("自定义：\(settings.translationModel)").tag(settings.translationModel)
                        }
                    }
                    .disabled(!settings.translationEnabled || viewModel.isRunning)

                    Toggle("同时显示原文（双语字幕）", isOn: $settings.showOriginalText)
                        .disabled(!settings.translationEnabled)

                    Text("转写模型逐字听写原文，文本模型并行翻译。原文准确、可双语显示；说话中先出半句预览译文，整句结束后替换为完整译文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .liveDirect:
                    Text("由通用 Live 模型（\(GeminiLiveModel.generalPurpose)）听音频后直接输出译文，只走一条连接、无原文。译文按整句出，偶尔会“回答”而不是翻译；若上方选择了专用转写模型，会自动改用通用模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("字幕显示") {
                LabeledContent("同时显示的最大字幕条数：\(settings.maxCaptionLines)") {
                    Slider(
                        value: Binding(
                            get: { Double(settings.maxCaptionLines) },
                            set: { settings.maxCaptionLines = Int($0.rounded()) }
                        ),
                        in: 1...5,
                        step: 1
                    )
                    .frame(width: 200)
                }

                LabeledContent("字幕停留时间：\(Int(settings.captionLifetimeSeconds)) 秒") {
                    Slider(value: $settings.captionLifetimeSeconds, in: 3...30, step: 1)
                        .frame(width: 200)
                }

                LabeledContent("字号：\(Int(settings.fontSize))") {
                    Slider(value: $settings.fontSize, in: 16...48, step: 1)
                        .frame(width: 200)
                }
            }

            Section("音频") {
                Picker("音频来源", selection: $settings.audioSource) {
                    ForEach(AudioSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .disabled(viewModel.isRunning)

                Text("系统音频需要在“系统设置 › 隐私与安全性 › 屏幕录制”中授权。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("连接") {
                LabeledContent("心跳间隔：\(Int(settings.keepAliveIntervalSeconds)) 秒") {
                    Slider(value: $settings.keepAliveIntervalSeconds, in: 5...30, step: 1)
                        .frame(width: 200)
                }

                LabeledContent("状态") {
                    Text(viewModel.connectionState.displayText)
                        .foregroundStyle(.secondary)
                }

                if let error = viewModel.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { apiKeyDraft = settings.apiKey }
    }
}
