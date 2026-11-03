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

                TextField("模型名称", text: $settings.modelName)
                    .textFieldStyle(.roundedBorder)

                Picker("字幕来源", selection: $settings.captionSource) {
                    ForEach(CaptionSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
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
