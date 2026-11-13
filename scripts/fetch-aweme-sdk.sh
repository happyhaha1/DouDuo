#!/bin/sh
# 从本机抖音 IPA 抽出原生请求栈（AwemeCore 及其全部非 weak 依赖 framework），放到 Vendor/Aweme/
# 用途：DouDuo 直接复用官方 MetaSec/TTNet 做原生接口签名，见 docs/native-signer.md
# 需要：本机已解密的 IPA（App Store 下载的加密包不可用，cryptid != 0）
set -e
cd "$(dirname "$0")/.."
IPA=${1:-$HOME/Downloads/抖音_41.1.0.ipa}
DEST=Vendor/Aweme
[ -f "$IPA" ] || { echo "❌ 找不到 IPA：$IPA"; exit 1; }

if [ -d "$DEST" ]; then
  echo "已存在 $DEST（$(du -sh "$DEST" | cut -f1)），跳过；要重抽先删除它"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/aweme.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
echo "→ 解包 Frameworks（约 1.1GB）…"
unzip -q "$IPA" 'Payload/Aweme.app/Frameworks/*' -d "$WORK"
FW="$WORK/Payload/Aweme.app/Frameworks"
[ -d "$FW" ] || { echo "❌ IPA 里没有 Frameworks，可能不是 Aweme.app"; exit 1; }

# 加密包检测：主二进制 cryptid 非 0 时它只能在真机上解密，静态抽出来也用不了
CRYPT=$(otool -l "$FW/AwemeCore.framework/AwemeCore" | awk '/LC_ENCRYPTION_INFO/{f=1} f&&/cryptid/{print $2; exit}')
[ "$CRYPT" = "0" ] || { echo "❌ AwemeCore cryptid=$CRYPT，这是加密包，需要已脱壳的 IPA"; exit 1; }

# 依赖闭包：从 AwemeCore 出发，在 Frameworks 目录内递归解析 @rpath 依赖（忽略 weak）
LIST=$(mktemp)
echo AwemeCore >> "$LIST"
i=1
while [ "$i" -le 64 ]; do
  i=$((i + 1))
  CHANGED=0
  for name in $(sort -u "$LIST"); do
    bin="$FW/$name.framework/$name"
    [ -f "$bin" ] || continue
    [ -f "$LIST.$name" ] && continue
    : > "$LIST.$name"
    otool -L "$bin" | tail -n +2 | while read -r dep rest; do
      case "$dep" in
        @rpath/*.framework/*)
          d=${dep#@rpath/}
          dn=${d%%.framework*}
          [ "$dn" = "$name" ] && continue
          echo "$rest" | grep -q weak || echo "$dn" >> "$LIST"
          ;;
      esac
    done
    CHANGED=1
  done
  sort -u "$LIST" -o "$LIST"
  [ "$CHANGED" = "1" ] || break
done
rm -f "$LIST".*

mkdir -p "$DEST"
for name in $(sort -u "$LIST"); do
  src="$FW/$name.framework"
  [ -d "$src" ] || { echo "⚠️  缺 $name.framework（IPA 里没有）"; continue; }
  cp -R "$src" "$DEST/"
done
rm -f "$LIST"

printf '%s\n' "$(ls "$DEST" | sed 's/\.framework$//')" > "$DEST/frameworks.txt"
echo "✅ $(wc -l < "$DEST/frameworks.txt" | tr -d ' ') 个 framework → $DEST（$(du -sh "$DEST" | cut -f1)）"
cat "$DEST/frameworks.txt" | tr '\n' ' '; echo
