#!/usr/bin/env bash
#
# 为 OpenWrt / ImmortalWrt 交叉编译锐捷认证客户端。
#
# 三种用法:
#   ./build-go.sh                        列出所有目标 + DISTRIB_ARCH 对照表
#   ./build-go.sh arm64                  直接给目标名
#   ./build-go.sh aarch64_cortex-a53     直接给路由器上的 DISTRIB_ARCH（自动换算）
#
# 路由器上查架构:
#   . /etc/openwrt_release; echo $DISTRIB_ARCH
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"
SOURCE="$REPO_ROOT/main.go"
OUT_DIR="$HERE/prebuilt"

# 目标名 -> "GOARCH GOMIPS GOARM 说明"
target_info() {
	case "$1" in
		amd64)              echo "amd64|||x86_64 软路由 / 虚拟机" ;;
		386)                echo "386|||32 位 x86（很少见）" ;;
		arm64)              echo "arm64|||aarch64：mediatek/filogic、qualcommax/ipq807x" ;;
		arm-v7)             echo "arm||7|32 位 ARMv7" ;;
		arm-v6)             echo "arm||6|32 位 ARMv6" ;;
		arm-v5)             echo "arm||5|32 位 ARMv5" ;;
		mipsle-softfloat)   echo "mipsle|softfloat||小端 MIPS：ramips mt7620 / mt7621 / mt7628" ;;
		mips-softfloat)     echo "mips|softfloat||大端 MIPS（少见）" ;;
		mips64le-softfloat) echo "mips64le|softfloat||64 位小端 MIPS：mt7622" ;;
		mips64-softfloat)   echo "mips64|softfloat||64 位大端 MIPS" ;;
		riscv64)            echo "riscv64|||RISC-V 64" ;;
		*)                  echo "" ;;
	esac
}

TARGET_LIST="amd64 386 arm64 arm-v7 arm-v6 arm-v5 mipsle-softfloat mips-softfloat mips64le-softfloat mips64-softfloat riscv64"

# 路由器上的 DISTRIB_ARCH -> 本脚本的目标名
normalize_arch() {
	case "$1" in
		x86_64)                      echo amd64 ;;
		i386)                        echo 386 ;;
		aarch64*)                    echo arm64 ;;
		# 注意通配符 * ：OpenWrt 的 DISTRIB_ARCH 常常是
		# arm_cortex-a7_neon-vfpv4 这种带后缀的长串，不是只有 arm_cortex-a7
		arm_cortex-a5*|arm_cortex-a7*|arm_cortex-a8*|arm_cortex-a9*|arm_cortex-a15*|arm_cortex-a17*)
		                             echo arm-v7 ;;
		arm_arm1176jzf-s*|arm_arm1136jf-s*) echo arm-v6 ;;
		arm_arm926ej-s*|arm_xscale*|arm_fa526*) echo arm-v5 ;;
		mipsel_*)                    echo mipsle-softfloat ;;
		mips64el_*)                  echo mips64le-softfloat ;;
		mips64_*)                    echo mips64-softfloat ;;
		mips_*)                      echo mips-softfloat ;;
		riscv64*)                    echo riscv64 ;;
		*)                           echo "" ;;
	esac
}

usage() {
	cat <<'EOF'

用法:
  ./build-go.sh                        # 列出所有目标和对照表
  ./build-go.sh <目标>                 # 例: ./build-go.sh arm64
  ./build-go.sh <DISTRIB_ARCH>         # 例: ./build-go.sh aarch64_cortex-a53

目标与路由器架构对照:

  目标                 路由器上的 DISTRIB_ARCH              说明
  ------------------   ---------------------------------   ------------------------------------------
  amd64                x86_64                              x86 软路由 / 虚拟机
  386                  i386                                32 位 x86（很少见）
  arm64                aarch64_cortex-a53, aarch64_*       MT7981 / MT7986 / IPQ807x / 树莓派等
  arm-v7               arm_cortex-a7, arm_cortex-a9, ...   32 位 ARMv7
  arm-v6               arm_arm1176jzf-s_vfp                32 位 ARMv6
  arm-v5               arm_xscale                          32 位 ARMv5
  mipsle-softfloat     mipsel_24kc, mipsel_*               ramips mt7620 / mt7621 / mt7628
  mips-softfloat       mips_24kc, mips_*                   大端 MIPS（少见）
  mips64le-softfloat   mips64el_*                          64 位小端 MIPS：mt7622
  mips64-softfloat     mips64_*                            64 位大端 MIPS
  riscv64              riscv64_*                           RISC-V 64

在路由器上查架构:
  . /etc/openwrt_release; echo $DISTRIB_ARCH

EOF
}

if [ $# -lt 1 ]; then
	usage
	exit 0
fi

INPUT="$1"
TARGET="$INPUT"

# 输入里带下划线就当成路由器上的 DISTRIB_ARCH，自动换算成目标名
case "$INPUT" in
	*_*)
		DERIVED="$(normalize_arch "$INPUT")"
		if [ -z "$DERIVED" ]; then
			echo "错误: 不认识的 DISTRIB_ARCH: $INPUT" >&2
			usage >&2
			exit 1
		fi
		TARGET="$DERIVED"
		echo "DISTRIB_ARCH '$INPUT' -> 编译目标 '$TARGET'"
		;;
esac

INFO="$(target_info "$TARGET")"
if [ -z "$INFO" ]; then
	echo "错误: 不认识的目标: $TARGET" >&2
	usage >&2
	exit 1
fi

IFS='|' read -r GOARCH GOMIPS GOARM DESC <<EOF
$INFO
EOF

if ! command -v go >/dev/null 2>&1; then
	echo "找不到 go 命令。装一个：" >&2
	echo "    sudo apt update && sudo apt install -y golang-go" >&2
	echo "或装官方最新版: https://go.dev/dl/" >&2
	exit 1
fi

if [ ! -f "$SOURCE" ]; then
	echo "找不到源文件: $SOURCE" >&2
	exit 1
fi

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/ruijie-$TARGET"

echo
echo "目标      : $TARGET  ($DESC)"
echo "GOOS/ARCH : linux/$GOARCH${GOMIPS:+ GOMIPS=$GOMIPS}${GOARM:+ GOARM=$GOARM}"
echo "输出      : $OUT"
echo

export GOOS=linux
export GOARCH
export CGO_ENABLED=0

# 空值不要导出，否则 Go 可能把空的 GOMIPS/GOARM 当成有效设置
if [ -n "$GOMIPS" ]; then export GOMIPS; else unset GOMIPS || true; fi
if [ -n "$GOARM" ];  then export GOARM;  else unset GOARM  || true; fi

# main.go 是单个文件、没有 go.mod，按文件参数直接编译即可
( cd "$REPO_ROOT" && go build -trimpath -ldflags '-s -w' -o "$OUT" main.go )

if [ ! -f "$OUT" ]; then
	echo "go build 失败" >&2
	exit 1
fi

SIZE="$(stat -c %s "$OUT")"

echo "编译完成"
printf '  文件大小 : %s bytes (%.1f MB)\n' \
	"$SIZE" "$(awk -v s="$SIZE" 'BEGIN { printf "%.1f", s / 1048576 }')"

# ---- ELF 头校验：编错架构是这类包最常见的坑 ----
if command -v file >/dev/null 2>&1; then
	printf '  格式校验 : %s\n' "$(file -b "$OUT")"
elif command -v readelf >/dev/null 2>&1; then
	echo "  格式校验 :"
	readelf -h "$OUT" | grep -E 'Class:|Data:|Machine:' | sed 's/^/    /'
else
	echo "  格式校验 : 跳过（装 file 或 binutils 就能看到）"
fi

echo
echo "下一步（用 SDK 打包）:"
echo "  ./build-ipk.sh <SDK目录>"
echo
