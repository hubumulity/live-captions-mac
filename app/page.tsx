const modules = [
  {
    title: '第一步：UI 与配置',
    files: ['App/LiveCaptionsApp.swift', 'Views/OverlayPanelController.swift', 'Views/CaptionOverlayView.swift', 'Views/SettingsView.swift', 'Services/KeychainStore.swift'],
    summary: '菜单栏常驻应用；NSPanel 透明置顶浮窗，可整窗拖拽、不抢焦点；API Key 存 Keychain；字幕行数 1~5 可调，旧行向上滚动淡出。',
  },
  {
    title: '第二步：音频采集与本地过滤',
    files: ['Audio/MicrophoneCapture.swift', 'Audio/SystemAudioCapture.swift', 'Audio/VoiceActivityDetector.swift', 'Audio/SpeechGate.swift'],
    summary: 'AVAudioEngine / ScreenCaptureKit 采集并重采样为 16 kHz PCM16；自适应 VAD + 片段级预滚缓冲，通过频谱质心/过零率波动与音节数判定，丢弃“嗯、啊”等语气词和喘息。',
  },
  {
    title: '第三步：Gemini Live 网络层',
    files: ['Network/GeminiLiveClient.swift', 'Network/GeminiMessages.swift'],
    summary: 'actor 封装 WebSocket：关闭服务端 VAD，按 activityStart / audio / activityEnd 发送；定时 Ping 保活；指数退避重连并携带 sessionResumption handle 无缝续接；响应 goAway 提前重连。',
  },
]

export default function Page() {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-3xl flex-col gap-10 px-6 py-16">
      <header className="flex flex-col gap-3">
        <p className="text-sm font-medium text-muted-foreground">macOS 15 · Swift 6 · SwiftUI</p>
        <h1 className="text-3xl font-semibold tracking-tight">Live Captions for macOS</h1>
        <p className="text-base leading-relaxed text-muted-foreground">
          基于 Gemini Live API 的实时字幕应用。源码位于项目的{' '}
          <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-sm">LiveCaptions/</code>{' '}
          目录，请下载后在 Xcode 中创建 macOS App target 并导入这些文件。此页面仅作为代码结构概览，应用本身不在浏览器中运行。
        </p>
      </header>

      <section aria-labelledby="modules-heading" className="flex flex-col gap-6">
        <h2 id="modules-heading" className="text-lg font-semibold">
          模块说明
        </h2>
        <ol className="flex flex-col gap-4">
          {modules.map((module) => (
            <li key={module.title} className="flex flex-col gap-3 rounded-lg border border-border p-5">
              <h3 className="font-medium">{module.title}</h3>
              <p className="text-sm leading-relaxed text-muted-foreground">{module.summary}</p>
              <ul className="flex flex-wrap gap-2">
                {module.files.map((file) => (
                  <li key={file} className="rounded bg-muted px-2 py-1 font-mono text-xs">
                    {file}
                  </li>
                ))}
              </ul>
            </li>
          ))}
        </ol>
      </section>

      <section aria-labelledby="setup-heading" className="flex flex-col gap-3">
        <h2 id="setup-heading" className="text-lg font-semibold">
          Xcode 接入要点
        </h2>
        <ul className="flex list-disc flex-col gap-2 pl-5 text-sm leading-relaxed text-muted-foreground">
          <li>Target 最低版本 macOS 15，Swift Language Version 6，开启 Strict Concurrency。</li>
          <li>
            使用 <code className="font-mono">Resources/Info.plist</code> 与{' '}
            <code className="font-mono">Resources/LiveCaptions.entitlements</code>（麦克风、系统音频、网络、Keychain）。
          </li>
          <li>系统音频采集需在「系统设置 → 隐私与安全性 → 屏幕录制」中授权。</li>
          <li>首次运行后在设置窗口填写 Gemini API Key，再从菜单栏点击「开始字幕」。</li>
        </ul>
      </section>
    </main>
  )
}
