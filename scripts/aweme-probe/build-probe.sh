#!/bin/sh
# 打一个真机可装的 AwemeProbe.app / .ipa（自签证书或 Sideloadly 侧载后运行）
# 前置：./scripts/fetch-aweme-sdk.sh 已把 framework 抽到 Vendor/Aweme/
set -e
cd "$(dirname "$0")/../.."
SRC=scripts/aweme-probe
FW=Vendor/Aweme
OUT=${OUT:-build/aweme-probe}
APP=$OUT/AwemeProbe.app

[ -d "$FW" ] || { echo "❌ 缺少 $FW，先跑 ./scripts/fetch-aweme-sdk.sh <IPA>"; exit 1; }
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

rm -rf "$OUT"; mkdir -p "$APP/Frameworks"

echo "→ 编译 probe"
OBJ=$OUT/obj
mkdir -p "$OBJ"
# main.m 走 ARC；mscall.m 必须 -fno-objc-arc（objc_msgSend 直调，手工所有权）
xcrun --sdk iphoneos clang -arch arm64 -target arm64-apple-ios17.0 -isysroot "$SDK" \
  -fobjc-arc -O1 -Wall -c "$SRC/main.m" -o "$OBJ/main.o"
xcrun --sdk iphoneos clang -arch arm64 -target arm64-apple-ios17.0 -isysroot "$SDK" \
  -fno-objc-arc -O1 -Wall -c "$SRC/mscall.m" -o "$OBJ/mscall.o"
xcrun --sdk iphoneos clang -arch arm64 -target arm64-apple-ios17.0 -isysroot "$SDK" \
  -framework UIKit -framework Foundation \
  -Wl,-rpath,@executable_path/Frameworks \
  -o "$APP/AwemeProbe" "$OBJ/main.o" "$OBJ/mscall.o"
rm -rf "$OBJ"
cp "$SRC/Info.plist" "$APP/Info.plist"

echo "→ 拷入 framework（约 1.1GB）"
for d in "$FW"/*.framework; do
  cp -R "$d" "$APP/Frameworks/"
done

echo "→ 自签（ad-hoc）"
for d in "$APP"/Frameworks/*.framework; do
  codesign -f -s - "$d" >/dev/null 2>&1
done
codesign -f -s - --entitlements /dev/null "$APP" >/dev/null 2>&1 || codesign -f -s - "$APP"
codesign -v "$APP" && echo "  签名校验通过"

echo "→ 打 ipa（.ipa 根下必须是 Payload/，否则安装器与签名工具都读不到）"
STAGE="$OUT/.ipa-stage"
rm -rf "$STAGE" "$OUT/AwemeProbe.ipa"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
ABS_OUT="$(cd "$OUT" && pwd)"
(cd "$STAGE" && zip -qry "$ABS_OUT/AwemeProbe.ipa" Payload)
rm -rf "$STAGE"
unzip -l "$OUT/AwemeProbe.ipa" | grep -qE ' Payload/AwemeProbe\.app/$' || { echo "✗ ipa 结构不对（根下没有 Payload/AwemeProbe.app/）"; exit 1; }
echo "✅ $OUT/AwemeProbe.ipa（$(du -sh "$OUT/AwemeProbe.ipa" | cut -f1)）"
echo "   装法：Sideloadly / AltStore 选这个 ipa；启动后看屏幕日志，或用 Console.app 过滤 [awemeprobe]"
