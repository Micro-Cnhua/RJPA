#!/usr/bin/env bash
#
# 在 Ubuntu / Debian / 任何 Linux 上用 ImmortalWrt SDK 把本目录打成 .ipk
#
# 用法:
#   ./build-ipk.sh <SDK目录>
#
# 例（MT7981B / Filogic 820）:
#   ./build-ipk.sh ~/sdk/immortalwrt-sdk-24.10.6-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64
#
# 说明: 一次会把 Makefile 里的两个包（rjpa + luci-rjpa）都编出来。
#       rjpa 包只是拷一个二进制进去，几乎不额外耗时。
#
# 说明:
#   Go 二进制要先用 build-go.sh 编好（放在 prebuilt/）。
#   本脚本只负责「拷进 SDK → 编译 → 找产物」。
#   SDK 放哪里都行，放在项目目录里面也可以（脚本只显式拷贝需要的几个子目录）。
#
# 耗时参考:
#   首次: make defconfig 约 30~90 秒（无输出）+ 编译约 2~10 分钟
#   之后: 单独重编某个包约 10~30 秒
#   如果 SDK 放在共享文件夹/网络盘里，上面每个数字都要乘以几十。

set -euo pipefail

say() {
	printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

if [ $# -lt 1 ]; then
	echo "用法: $0 <SDK目录>" >&2
	echo "例:   $0 ~/sdk/immortalwrt-sdk-24.10.6-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64" >&2
	exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK_IN="$1"
if [ $# -gt 1 ]; then
	echo "提示: 多余的参数会被忽略——本脚本一次编出 Makefile 里的所有包。" >&2
fi

if [ ! -d "$SDK_IN" ]; then
	echo "错误: 找不到 SDK 目录 $SDK_IN" >&2
	exit 1
fi

SDK="$(cd "$SDK_IN" && pwd)"

if [ ! -f "$SDK/rules.mk" ]; then
	echo "错误: $SDK 看起来不是 OpenWrt/ImmortalWrt SDK（找不到 rules.mk）" >&2
	echo "      你给的是 SDK 解压出来的那一层目录吗？" >&2
	exit 1
fi

# ------------------------------------------------------------------ 0. 环境体检
# SDK 落在共享文件夹 / 网络盘上是「make 慢到像卡死」最常见的原因
if command -v findmnt >/dev/null 2>&1; then
	SDK_FS="$(findmnt -no FSTYPE --target "$SDK" 2>/dev/null || echo unknown)"
	case "$SDK_FS" in
		hgfs|vboxsf|9p|nfs|nfs4|cifs|smb3|prl_fs|fuse*)
			echo
			echo "警告: SDK 位于 $SDK_FS 挂载上：$SDK" >&2
			echo "      在共享文件夹 / 网络盘上跑 make 会慢几十倍，而且容易报奇怪的权限错误。" >&2
			echo "      请把它移到本地磁盘。" >&2
			echo
			;;
	esac
fi

# 磁盘空间：编译过程要写好几个 GB
FREE_MB="$(df -Pk "$SDK" 2>/dev/null | awk 'NR==2 { print int($4 / 1024) }')"
if [ -n "${FREE_MB:-}" ] && [ "$FREE_MB" -lt 3072 ] 2>/dev/null; then
	echo "警告: $SDK 所在分区只剩约 ${FREE_MB}MB，编译很可能中途失败，建议先腾出 3GB 以上。" >&2
fi

# ------------------------------------------------------------------ 1. 检查二进制
say "检查 prebuilt/ 里的 Go 二进制"
if ! ls "$HERE"/prebuilt/rjpa-* >/dev/null 2>&1; then
	echo "错误: prebuilt/ 里没有任何 rjpa-* 二进制。" >&2
	echo "      Linux:   ./build-go.sh           然后 ./build-go.sh <目标>" >&2
	echo "      Windows: .\\build-go.ps1 -List    然后 .\\build-go.ps1 -Target <目标>" >&2
	exit 1
fi
ls -l "$HERE"/prebuilt/rjpa-* | sed 's/^/    /'

# ------------------------------------------------------------------ 2. 拷进 SDK
DEST="$SDK/package/rjpa"
say "同步包源码到 $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"

# 只显式拷贝打包真正需要的这几项。
#
# 这里刻意不用 `tar -C "$HERE" . | tar -C "$DEST" -xf -` 这种整目录拷贝：
# 如果 SDK 恰好解压在项目目录里面（例如 openwrt/sdk/），
# 整目录拷贝会把 SDK 自己拷进 sdk/package/rjpa/ 里面，
# 而那又在这棵树里 —— 无限递归，直到把磁盘写满。
for item in Makefile files luci-root prebuilt; do
	if [ ! -e "$HERE/$item" ]; then
		echo "错误: 项目目录里缺少 $item，$HERE 看起来不完整。" >&2
		exit 1
	fi
	cp -a "$HERE/$item" "$DEST/"
done
say "已拷贝: $(ls "$DEST" | tr '\n' ' ')"

cd "$SDK"

# ------------------------------------------------------------------ 3. 生成 .config
say "生成 SDK 配置 .config"
echo "    首次运行约 30~90 秒，这期间屏幕上不会动，属正常现象，不要以为卡死了。"
CONFIG_LOG="$SDK/tmp/rjpa-defconfig.log"
mkdir -p "$SDK/tmp"
if ! make defconfig >"$CONFIG_LOG" 2>&1; then
	echo "    defconfig 失败了，完整输出：$CONFIG_LOG" >&2
	tail -n 40 "$CONFIG_LOG" >&2
	exit 1
fi
say "配置完成（日志: $CONFIG_LOG）"

# ------------------------------------------------------------------ 3.5 选包
# 显式启用要打的两个包。
#
# OpenWrt 只构建 .config 里被选中的包，没选中的会被**静默跳过**（不报错、
# 也不产出），见 include/package-pack.mk 里的 CONFIG_PACKAGE_$(1) 判断。
# 我们的包不是发行版默认包，defconfig 不会自动选上，所以必须手动打开。
#
# 必须放在 defconfig 之后：defconfig 会重算整个 .config。
for pkg in rjpa luci-rjpa; do
	grep -q "^CONFIG_PACKAGE_${pkg}=y\$" .config 2>/dev/null || \
		printf 'CONFIG_PACKAGE_%s=y\n' "$pkg" >> .config
done

say "已显式启用的包:"
grep -E '^CONFIG_PACKAGE_(rjpa|luci-rjpa)=' .config | sed 's/^/    /'

# 确认真的写进去了，否则后面会以"编不出来"的形式失败，不好排查
for pkg in rjpa luci-rjpa; do
	if ! grep -q "^CONFIG_PACKAGE_${pkg}=y\$" .config; then
		echo "" >&2
		echo "*** 启用 $pkg 失败，.config 里没有 CONFIG_PACKAGE_${pkg}=y" >&2
		grep -n "CONFIG_PACKAGE_${pkg}" .config >&2 || echo "    （这个包在 .config 里一次都没出现）" >&2
		exit 1
	fi
done

# ------------------------------------------------------------------ 4. 编译
say "开始编译 package/rjpa"
echo "    首次编译 SDK 要先跑一遍 prepare，约 2~10 分钟；之后再编同一个包只要十几秒。"
echo "    下面会滚动大量输出（V=s），这是正常的。"
make package/rjpa/compile V=s
say "编译结束"

# ------------------------------------------------------------------ 5. 找产物
# 同时收 opkg 的 .ipk 和 apk 的 .apk：
# 24.10 的 SDK 出 .ipk，25.12 的 SDK 出 .apk，用哪套 SDK 就出哪种。
PKG_FIND=(find "$SDK/bin" -type f \( \
	-name 'rjpa_*.ipk' -o -name 'luci-rjpa_*.ipk' -o \
	-name 'rjpa-*.apk' -o -name 'luci-rjpa-*.apk' \))

echo
echo "==> 产物"
CORE=0
LUCI=0
while IFS= read -r f; do
	[ -n "$f" ] || continue
	case "$f" in
		*/luci-rjpa[_-]*) LUCI=$((LUCI + 1)) ;;
		*/rjpa[_-]*)      CORE=$((CORE + 1)) ;;
	esac
	echo "    $f"
done < <("${PKG_FIND[@]}" 2>/dev/null | sort)

# 两个包都必须产出。
#
# 之前只判断"找到了任何东西没有"，于是 luci-rjpa 因为依赖选不上、
# 压根没被构建时，这个问题被静默吞掉了 —— 只编出一个包也算成功。
if [ "$CORE" -eq 0 ] || [ "$LUCI" -eq 0 ]; then
	echo "" >&2
	echo "*** 产物不全: rjpa 包 $CORE 个, luci-rjpa 包 $LUCI 个，两个都必须有。" >&2
	echo "*** SDK 里实际产出的包如下，便于定位:" >&2
	find "$SDK/bin" -type f \( -name '*.ipk' -o -name '*.apk' \) 2>/dev/null | sed 's/^/      /' >&2
	echo "*** 常见原因: LuCI 包的依赖在 SDK 里不存在，导致它没被构建。" >&2
	echo "***           检查 Makefile 里 luci-compat / luci-lua-runtime 前面是不是带了 +" >&2
	exit 1
fi

say "拷回 $HERE/dist/"
mkdir -p "$HERE/dist"
"${PKG_FIND[@]}" -exec cp -f {} "$HERE/dist/" \; 2>/dev/null || true
ls -l "$HERE/dist" | sed 's/^/    /'

echo
echo "完成。把 dist/ 里的包传到路由器："
echo
echo "  24.10 及更早（opkg / .ipk）:"
echo "    opkg install luci-compat luci-lua-runtime   # 首次需要，Lua 版 LuCI 支持"
echo "    opkg install ./rjpa_*.ipk ./luci-rjpa_*.ipk"
echo
echo "  25.12 及以后（apk / .apk）:"
echo "    apk add luci-compat luci-lua-runtime"
echo "    apk add --allow-untrusted ./rjpa-*.apk ./luci-rjpa-*.apk"
echo
echo "  装完都执行:"
echo "    /etc/init.d/uhttpd restart"
