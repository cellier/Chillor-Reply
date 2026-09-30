# Chillor Reply

Chillor 系列的原生 macOS 翻译与回复工具。通过快捷键或受支持 MacBook 的轻拍触发，在内容附近显示玻璃浮层，本机完成翻译、起草和回译。

[English](README.md) · [技术架构](docs/ARCHITECTURE.md) · [隐私说明](docs/PRIVACY.md)

## 界面与视频导览

[![Chillor Reply 截图导览：查看翻译，再审阅双语回复](docs/media/walkthrough.gif)](https://github.com/cellier/Chillor-Reply/raw/refs/heads/main/docs/media/walkthrough.mp4)

[观看 / 下载 MP4 视频导览](https://github.com/cellier/Chillor-Reply/raw/refs/heads/main/docs/media/walkthrough.mp4)

*约 12 秒的截图导览，使用虚构消息。素材来自实际开发版本的界面截图，并非实时操作录屏，也不代表模型响应速度。翻译截图展示的是生成中的状态。*

| 阅读翻译 | 审阅与编辑回复 |
| --- | --- |
| <img src="docs/media/translation.png" alt="内容附近的玻璃浮层显示中文翻译" width="360"> | <img src="docs/media/reply.png" alt="中文草稿、英文回复与独立中文回译" width="360"> |

## 工作流程

读取指针附近的内容 → 翻译来信 → 建议中文草稿 → 生成英文 → 独立中文回译 → 用户确认后复制或填回。应用不会自动发送消息。中文草稿、英文和后续修改均可审阅；界面随系统语言切换中英文。

可选的本地记忆保存文字历史、术语和回复偏好；可暂停、纠正或删除。历史对话事实不会自动作为新回复的事实依据。

## 构建与使用

当前版本为 0.10.6 实验版。支持 Apple Silicon，运行目标为 macOS 14+；编译包含 Liquid Glass 的代码需要 Xcode 26 或更新版本及其 macOS SDK。旧系统使用兼容控件。

模型为 Ollama 0.33.3 + Qwen 3.8 27B（Q4_K_M），下载约 17.7 GB，权重不在仓库中。已在 48 GB 内存的 Mac 上验证；尚未确定最低内存要求，运行还需要额外内存。

安装并完成 Xcode 首次配置后，在仓库目录运行：

```sh
./build.sh "$PWD/build"
open "build/Chillor Reply.app"
```

脚本下载固定版本的官方 Ollama 运行时，直接编译 Swift，执行本机签名及自动化测试。可用 `REPLYLENS_RUNTIME_DIR` 指向已有的解压运行时，避免重复下载。

在系统设置中按需开启辅助功能、屏幕录制，然后退出并重开应用。模型通过应用内首次启动或设置流程下载，可断点续传。构建产物默认未公证；重新编译可能需要重新授权。

把指针放在消息附近，按 **Control–Option–Space** 识别。检查回译，确认后复制或填回；不支持填回的编辑器使用复制粘贴。

轻拍依赖未公开的运动传感器接口，受机型、系统版本和摆放位置影响，仍属实验功能。当前可见内容不代表完整会话，模型输出需要人工确认。

## 测试与公开范围

构建自动执行 OCR、记忆、回复状态、轻拍及本地化测试；这些测试使用合成样例，无需模型。真实模型测试通过 `--model-test` 单独运行，使用虚构消息。

公开内容仅包括源代码、资源和开发说明。个人聊天、截图、传感器录音、记忆数据库、密钥、模型文件和开发日志不随仓库发布。

项目源码采用 [MIT 许可证](LICENSE)；第三方依赖仍遵循其各自许可。历史 ReplyLens 标识保留以兼容权限、模型目录和本地数据。

## SDK 排错

本机使用 Swift 6.4 + macOS 26.5 SDK 验证通过。如果只有 Command Line Tools、默认 SDK 为 macOS 27，可能遇到 `SwiftUIMacros.StateMacro` 缺失。请选择完整 Xcode 工具链，或通过 `SDKROOT` 指向已安装的 macOS 26.5 SDK。具体命令见英文说明。
