prebuilt/ 放交叉编译好的 Go 二进制，文件名必须和 OpenWrt 的 ARCH 对应：

    rjpa-amd64                    x86_64
    rjpa-386                      i386
    rjpa-arm64                    aarch64   ← MT7981B / Filogic 820 用这个
    rjpa-arm-v7 / -v6 / -v5       arm
    rjpa-mipsle-softfloat         mipsel
    rjpa-mips-softfloat           mips
    rjpa-mips64le-softfloat       mips64el
    rjpa-mips64-softfloat         mips64
    rjpa-riscv64                  riscv64

生成方法：两个脚本的目标命名完全一致，用哪个都行，产物可以混用。

    # Linux / Ubuntu
    ./build-go.sh                  # 列出全部目标
    ./build-go.sh arm64            # 编译指定目标

    # Windows PowerShell（文件必须存成 UTF-8 with BOM）
    .\build-go.ps1 -List
    .\build-go.ps1 -Target arm64

打 .ipk 时 Makefile 会按当前 SDK 的 ARCH 自动挑选对应文件，
找不到就报错并提示应该编译哪个目标。

注意: 这里放的是构建产物，按需重新生成即可。
      别把无关架构的二进制长期堆在这里（每个几 MB）。
