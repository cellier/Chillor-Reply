#!/bin/zsh
set -eu
task_source_dir="$(cd "$(dirname "$0")" && pwd)"
task_output="${1:-$task_source_dir/build}"
task_runtime="${REPLYLENS_RUNTIME_DIR:-$task_output/runtime-download}"
mkdir -p "$task_output/Chillor Reply.app/Contents/MacOS" "$task_output/Chillor Reply.app/Contents/Resources/runtime"
if [[ ! -x "$task_runtime/ollama" ]]; then
  mkdir -p "$task_runtime"
  curl --fail --location --retry 3 'https://github.com/ollama/ollama/releases/download/v0.33.3/ollama-darwin.tgz' -o "$task_runtime/ollama-darwin.tgz"
  tar -xzf "$task_runtime/ollama-darwin.tgz" -C "$task_runtime"
fi
cp "$task_source_dir/Info.plist" "$task_output/Chillor Reply.app/Contents/Info.plist"
cp "$task_source_dir/Resources/ReplyLens.icns" "$task_output/Chillor Reply.app/Contents/Resources/ReplyLens.icns"
for task_language in en zh zh-Hant; do
  mkdir -p "$task_output/Chillor Reply.app/Contents/Resources/$task_language.lproj"
  cp "$task_source_dir/Resources/$task_language.lproj/"*.strings "$task_output/Chillor Reply.app/Contents/Resources/$task_language.lproj/"
done
rsync -a --exclude '*.tgz' --exclude '*.log' --exclude '*.jsonl' "$task_runtime/" "$task_output/Chillor Reply.app/Contents/Resources/runtime/"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -framework Cocoa -framework SwiftUI -framework ScreenCaptureKit -framework Vision -framework Carbon -framework NaturalLanguage "$task_source_dir/main.swift" "$task_source_dir/MessageDetection.swift" "$task_source_dir/DetectionTests.swift" "$task_source_dir/LocalReply.swift" "$task_source_dir/ModelTests.swift" "$task_source_dir/TapTrigger.swift" "$task_source_dir/TapDetection.swift" "$task_source_dir/TapTests.swift" "$task_source_dir/ChillorUI.swift" "$task_source_dir/ResultOverlay.swift" "$task_source_dir/Localization.swift" "$task_source_dir/MemoryStore.swift" "$task_source_dir/MemoryView.swift" "$task_source_dir/MemoryTests.swift" -o "$task_output/Chillor Reply.app/Contents/MacOS/ChillorReply"
# A stable signing identity keeps the macOS accessibility and screen-recording
# grants across rebuilds. An ad-hoc signature is identified by its own hash, so
# every rebuild looks like a different application and every grant is lost.
task_identity="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "ReplyLens Local"; then
  task_identity="ReplyLens Local"
  echo "signing with the stable identity ReplyLens Local: existing permissions are kept"
else
  echo "no ReplyLens Local code-signing certificate; using an ad-hoc signature"
  echo "macOS will treat this build as a new application, so accessibility and screen recording have to be granted again"
fi
codesign --force --sign "$task_identity" --identifier local.cellier.replylens.prototype "$task_output/Chillor Reply.app"
codesign --verify --deep --strict "$task_output/Chillor Reply.app"
# -O compiles a failed precondition into a bare trap with no message, so a crashed
# test stage prints nothing at all. Bracket each stage; a missing BUILD OK is the signal.
echo "== self-test =="
"$task_output/Chillor Reply.app/Contents/MacOS/ChillorReply" --self-test
echo "== memory-test =="
"$task_output/Chillor Reply.app/Contents/MacOS/ChillorReply" --memory-test
echo "== automation-test =="
"$task_output/Chillor Reply.app/Contents/MacOS/ChillorReply" --automation-test


for task_language in en zh-Hans zh-Hant zh-TW fr; do
  "$task_output/Chillor Reply.app/Contents/MacOS/ChillorReply" --localization-test -AppleLanguages "($task_language)"
done

echo "== BUILD OK: $task_output/Chillor Reply.app =="
