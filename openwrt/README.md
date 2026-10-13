# 把 main.go 做成 ImmortalWrt 24.10 的 LuCI 软件包（Lua 模板 + 连接日志）

目标：把 `main.go`（锐捷 eportal 校园网认证客户端）编译成 `.ipk`，装到
ImmortalWrt 24.10 上，在 LuCI 里配置账号密码、并实时查看连接日志。

**环境：编译全部在一台 Ubuntu 24.04 虚拟机里完成**（Go 交叉编译 + SDK 打包），
测试机 ImmortalWrt 24.10，设备 **MT7981B（MediaTek Filogic 820）**。

> **只想直接装上用？不用自己编译。**
> 去 [Releases](../../releases) 下载和你路由器**架构**对应的
> `rjpa_*.ipk`，加上共用的 `luci-rjpa_*.ipk` 就能装。
> 怎么查自己的架构、以及为什么不需要按型号编译，见
> [第 12 节：别人（不同型号）怎么编译](#12-别人不同型号怎么编译)。

---

## 0. 三个前提结论（决定了整套做法）

**① 24.10 用 opkg + `.ipk`；25.12 起换成 apk + `.apk`。**

已核对两边的软件源：

| 版本 | 包管理器 | 产物 |
|---|---|---|
| 24.10.6 | opkg | `Packages` / `opkg_2024.10.16` / `*.ipk` |
| 25.12.2 | apk | `*.apk`（文件名形如 `包名-版本-r修订.apk`） |

**同一个 SDK 出不了两种格式**（25.12 已经移除 opkg），所以要出齐两种就得跑两套 SDK。
仓库里的 GitHub Actions 已经这么配了 —— 打一个 tag，同一个 Release 里同时有 `.ipk` 和 `.apk`。

下面第 5～6 节以 24.10 的 `.ipk` 为主，涉及 `.apk` 的差异会单独标出来。

**② 24.10 的 LuCI 前端已经是 ucode + JS，但 Lua 页面依然被官方支持。**
读过 24.10 分支的源码确认：

- `luci-lua-runtime` 里的 `dispatcher.lua` 提供 `process_lua_controller()`，
  ucode 分发器会调用它来读取你的 `controller/*.lua` 并注册菜单
  → **Lua 控制器注册的菜单会出现在 LuCI 左侧**。
- `luci-compat` 提供 `luasrc/cbi.lua`、`luasrc/view/cbi/header.htm`、
  `footer.htm`，CBI 表单靠它们渲染
  → **`cbi()` 页面能正常显示**。
- 旧主题模板（`themes/bootstrap/header.htm` 之类）在 23.05/24.10 **已经没有了**，
  但这不影响你：页面外壳由 ucode 侧负责，你的 `view/*.htm` 只需要写"片段"。

结论：**Lua 这条路是通的，但必须让 `luci-compat` + `luci-lua-runtime` 存在**。
这两个包在 24.10 的 luci 软件源里都有；ImmortalWrt 默认镜像**不预装**它们，
所以第 6 步的安装命令不能省。

**③ OpenWrt SDK 只有 Linux 版 —— 你现在正好在 Linux 里，这是最省事的组合。**

而且 `main.go` 只用 Go 标准库，**Go 二进制根本不需要 SDK**：普通交叉编译就行，
SDK 只负责把文件打成 `.ipk`。所以整条链路（编译 + 打包）都在同一台 Ubuntu 里跑完，
不用在 Windows / WSL / 虚拟机之间倒腾文件。

> 顺带说一句：**不要在 SDK 里用 `golang-package.mk` 编 Go**。
> 那要先补 golang feed、再编译一套 Go 工具链（几十分钟、还得联外网）。
> 你的程序纯标准库、无 cgo，直接交叉编译又快又稳。

---

## 1. 目录结构

```
openwrt/
├── Makefile                     # 包定义：rjpa + luci-rjpa
├── build-go.sh                  # 【Linux】交叉编译 Go 二进制
├── build-go.ps1                 # 【Windows】同上（目标命名完全一致）
├── build-ipk.sh                 # 用 SDK 打成 .ipk / .apk（取决于 SDK 是哪一代）
├── prebuilt/                    # Go 二进制产物（Makefile 按 ARCH 自动挑）
├── dist/                        # 打好的包输出到这里（脚本生成）
├── files/                       # → 装进 rjpa 包（后台服务，不依赖 LuCI）
│   ├── etc/config/rjpa        #   UCI 默认配置
│   └── etc/init.d/rjpa        #   procd 服务脚本
└── luci-root/                   # → 装进 luci-rjpa 包（Lua 界面）
    └── usr/
        ├── lib/lua/luci/
        │   ├── controller/rjpa.lua            # 菜单 + AJAX 接口（日志 / 服务类型检测）
        │   ├── model/cbi/rjpa/config.lua      # 基本设置表单（服务类型动态填充）
        │   └── view/rjpa/
        │       ├── status.htm                   # 运行状态 + 服务类型检测按钮
        │       └── log.htm                      # 连接日志框（嵌在基本设置页底部）
        └── share/rpcd/acl.d/luci-rjpa.json # 权限声明
```

拆成两个包是故意的：`rjpa` 是纯后台服务（不依赖 LuCI），
`luci-rjpa` 是界面（`PKGARCH:=all`，与架构无关）。
`luci-rjpa` 通过 `DEPENDS` 自动拉 `rjpa` 和 LuCI Lua 依赖。

---

## 2. 确认架构（MT7981B 可以直接跳过）

**MT7981B 的答案已经确定，不用查表：**

| 项目 | 值 |
|---|---|
| `DISTRIB_ARCH` | `aarch64_cortex-a53` |
| 编译目标（`build-go.sh`） | `arm64` |
| SDK target | `mediatek/filogic` |

只要顺手在路由器上确认一下**版本号**（SDK 下载地址里要用）和空间：

```sh
. /etc/openwrt_release; echo "$DISTRIB_RELEASE  |  $DISTRIB_ARCH"
df -h /overlay
```

预期类似 `24.10.6  |  aarch64_cortex-a53`。arm64 二进制约 6.4MB，MT7981B 的机器
一般 128MB+ flash，空间没问题。

<details>
<summary>如果不是 MT7981B，点开看完整对照表</summary>

| `DISTRIB_ARCH` | `build-go.sh` 目标 | SDK 的 target/subtarget | 典型设备 |
|---|---|---|---|
| `x86_64` | `amd64` | `x86/64` | x86 软路由 / 虚拟机 |
| `mipsel_24kc` | `mipsle-softfloat` | `ramips/mt7621`、`ramips/mt7620` | 新路由3、K2P、小米路由3G |
| `mips_24kc` | `mips-softfloat` | `ath79/generic` 等 | 部分老款 AR 芯片 |
| `aarch64_cortex-a53` | `arm64` | `mediatek/filogic` | **MT7981B**、AX3000T |
| `aarch64_generic` | `arm64` | `qualcommax/ipq807x` | AX3600、红米 AX6 |
| `arm_cortex-a7`、`arm_cortex-a9` | `arm-v7` | `bcm27xx`、`sunxi` 等 | 树莓派、部分 ARM 路由 |
| `riscv64` | `riscv64` | `riscv64/generic` | RISC-V 开发板 |

`./build-go.sh`（不带参数）会把这几个目标连说明一起打出来。

**SDK 必须和路由器同 target**，否则打出来的包装不上（架构不匹配）。

</details>

---

## 3. 第一步：把项目和环境准备好

### 3.1 装依赖

Ubuntu 24.04 里一条命令搞定：

```sh
sudo apt update
sudo apt install -y golang-go zstd make gcc file
```

- `golang-go` 在 Ubuntu 24.04 里是 Go 1.22，编 `main.go` 完全够用（纯标准库、无泛型）。
  想要最新版就去 <https://go.dev/dl/> 下官方 tar 包。
- `zstd` 是解压 SDK 用的（`.tar.zst`）。
- `make gcc` 是 SDK 打包必需，`file` 用来校验编出来的架构对不对。

### 3.2 把项目拿进虚拟机

用共享文件夹 / 拖拽 / `scp` / `git` 都行，最终在虚拟机里能 `cd` 到
`openwrt` 目录即可。比如 VMware 共享文件夹通常是：

```sh
cd /mnt/hgfs/Sync/个人/校园网/NewProgress/openwrt     # 路径按你自己的改
ls
```

**两个和路径有关的注意事项：**

1. **SDK 一定要放在虚拟机自己的磁盘上（比如 `~/sdk`），不要放共享文件夹。**
   `make` 在 hgfs / vboxsf 这类挂载点上容易因为权限和大小写问题出怪错，而且很慢。
2. 项目源码**可以**留在共享文件夹里。`build-ipk.sh` 会自己把包源码按需拷进 SDK，
   所以你不用手动 `cp` 来 `cp` 去。

如果要把项目拷到本地磁盘，也就一行：

```sh
cp -a /mnt/hgfs/Sync/个人/校园网/NewProgress/openwrt ~/rjpa-pkg
cd ~/rjpa-pkg
```

---

## 4. 第二步：编译 Go 二进制

```sh
cd openwrt
chmod +x build-go.sh build-ipk.sh
./build-go.sh              # 不带参数 = 列出所有可选目标
./build-go.sh arm64        # MT7981B
```

输出长这样：

```
目标      : arm64  (aarch64：mediatek/filogic、qualcommax/ipq807x)
GOOS/ARCH : linux/arm64
输出      : /home/you/openwrt/prebuilt/rjpa-arm64

编译完成
  文件大小 : 6422688 bytes (6.1 MB)
  格式校验 : ELF 64-bit LSB executable, ARM aarch64, ...
```

脚本做的事：导出 `GOOS=linux` / `GOARCH=arm64` / `CGO_ENABLED=0`
（MIPS 会带 `GOMIPS=softfloat`，ARM 带 `GOARM`），用
`-trimpath -ldflags "-s -w"` 编译，产物写到 `prebuilt/rjpa-<目标>`。

最后那行**架构校验是特意加的**——"给路由器编错架构"是这类包最常见的翻车点，
二进制传上去只会报 `Exec format error`。看到架构不对就换目标重编。

---

## 5. 第三步：下载 SDK 并打包

### 5.1 下载解压 SDK

MT7981B 对应的是 `mediatek/filogic`：

```
目录:   https://downloads.immortalwrt.org/releases/24.10.6/targets/mediatek/filogic/
文件:   immortalwrt-sdk-24.10.6-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst
sha256: 8b4340a9b7e8802a7ffa6feb99604a27025cf702baeab052b931f1bfa6a9f638
```

**把 URL 里的 `24.10.6` 换成第 2 步看到的实际版本号**
（上面的 sha256 只对应 24.10.6，换版本要重新核对）。

```sh
mkdir -p ~/sdk && cd ~/sdk

wget https://downloads.immortalwrt.org/releases/24.10.6/targets/mediatek/filogic/immortalwrt-sdk-24.10.6-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst

# 可选但推荐：核对一下
sha256sum immortalwrt-sdk-24.10.6-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst
# 应该输出 8b4340a9b7e8802a7ffa6feb99604a27025cf702baeab052b931f1bfa6a9f638

tar --zstd -xf immortalwrt-sdk-24.10.6-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst
ls -d ~/sdk/immortalwrt-sdk-*
```

下载约 500MB，解压后约 1.5GB，留够磁盘空间。

### 5.2 打包

```sh
cd ~/rjpa-pkg            # 或你放 openwrt 目录的地方
./build-ipk.sh ~/sdk/immortalwrt-sdk-24.10.6-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64
```

脚本流程：把包源码同步到 `<SDK>/package/rjpa` → `make defconfig`
→ `make package/rjpa/compile V=s` → 找出产物并拷到本目录 `dist/`。

用 **24.10.x 的 SDK** 出 `.ipk`，用 **25.12.x 的 SDK** 出 `.apk`。脚本按 SDK 实际产出
哪种就收哪种，不用改参数。

如果 `prebuilt/` 里没有当前架构需要的二进制，Makefile 会直接停下并告诉你该编哪个目标，
**不会产出装不上的包**：

```
*** 找不到 Go 二进制: /home/you/sdk/.../package/rjpa/prebuilt/rjpa-arm64
*** 当前 OpenWrt ARCH = aarch64，需要文件 rjpa-arm64
*** 请先编译:  ./build-go.sh arm64          (Linux)
***     或:    .\build-go.ps1 -Target arm64  (Windows)
```

### 5.3 产物

用 **24.10.x 的 SDK** 时：

```
dist/rjpa_1.0.0-1_aarch64_cortex-a53.ipk
dist/luci-rjpa_1.0.0-1_all.ipk
```

用 **25.12.x 的 SDK** 时（注意 apk 文件名里**不带架构**）：

```
dist/rjpa-1.0.0-r1.apk
dist/luci-rjpa-1.0.0-r1.apk
```

> ⚠️ apk 的文件名不带架构，所以**要为多个架构各出一份时得自己补架构后缀**，
> 否则同名会冲突。CI 里已经自动做了这件事，产物形如
> `rjpa-1.0.0-r1.aarch64_cortex-a53.apk`。
> 手动只编一个架构时无所谓——反正只有一份。

第一次编译 SDK 里的依赖索引要几十秒，之后重编就很快了（十几秒）。
脚本一次会把 `rjpa` 和 `luci-rjpa` 两个包都编出来——
`rjpa` 包只是拷一个二进制进去，几乎不额外耗时。

```sh
./build-ipk.sh ~/sdk/immortalwrt-sdk-24.10.6-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64
```

---

## 6. 第四步：装到路由器

从虚拟机直接 scp 过去（虚拟机要能访问到路由器）：

```sh
scp dist/* root@192.168.1.1:/tmp/
```

### 24.10 及更早（opkg / `.ipk`）

```sh
ssh root@192.168.1.1

opkg update

# 【关键】Lua 版 LuCI 支持，24.10 默认镜像没有预装
opkg install luci-compat luci-lua-runtime

cd /tmp
opkg install ./rjpa_*.ipk ./luci-rjpa_*.ipk

# 让新菜单立刻出现
/etc/init.d/uhttpd restart
rm -f /tmp/luci-indexcache*
```

### 25.12 及以后（apk / `.apk`）

```sh
ssh root@192.168.1.1

# 【关键】Lua 版 LuCI 支持，默认镜像同样没预装
apk add luci-compat luci-lua-runtime

cd /tmp
# 本地包没有用路由器的信任密钥签名，所以要加 --allow-untrusted
apk add --allow-untrusted ./rjpa-*.apk ./luci-rjpa-*.apk

/etc/init.d/uhttpd restart
rm -f /tmp/luci-indexcache*
```

> `luci-compat` / `luci-lua-runtime` 在 25.12 里**依然存在**（已核对 `openwrt-25.12`
> 和 ImmortalWrt 对应分支的源码），所以 Lua 界面不用重写。
>
> 下面"上不了外网"那一段以 opkg 为例，apk 把 `opkg install` 换成 `apk add` 即可。

### 如果路由器上不了外网怎么办

这里有个先有鸡还是先有蛋的问题：校园网认证客户端本身还没跑起来，
路由器可能根本连不上外网，`opkg install luci-compat` 会失败。

**办法 A（推荐）**：在 Ubuntu 里用 `wget` 把依赖包下下来，和 ipk 一起 scp 过去。
软件源地址格式：

```
https://downloads.immortalwrt.org/releases/24.10.6/packages/aarch64_cortex-a53/luci/
https://downloads.immortalwrt.org/releases/24.10.6/packages/aarch64_cortex-a53/base/
```

（`aarch64_cortex-a53` 就是第 2 步看到的 `DISTRIB_ARCH`。）需要的包：

```
luci/luci-compat_*.ipk
luci/luci-lua-runtime_*.ipk
luci/luci-lib-base_*.ipk
luci/luci-lib-nixio_*.ipk
luci/luci-lib-ip_*.ipk
luci/luci-lib-jsonc_*.ipk
base/lua_*.ipk
base/libubus-lua_*.ipk
base/liblucihttp-lua_*.ipk
base/liblucihttp0_*.ipk
base/ucode-mod-lua_*.ipk
```

一次性下载（在 Ubuntu 里）：

```sh
cd /tmp/deps
BASE=https://downloads.immortalwrt.org/releases/24.10.6/packages/aarch64_cortex-a53
for f in $(wget -qO- $BASE/luci/ | grep -oE 'luci-(compat|lua-runtime|lib-base|lib-nixio|lib-ip|lib-jsonc)_[^"]*\.ipk' | sort -u); do
	wget -q "$BASE/luci/$f"
done
```

然后 `scp /tmp/deps/*.ipk root@192.168.1.1:/tmp/`，
在路由器上 `cd /tmp && opkg install ./*.ipk`（opkg 会自己按依赖顺序处理，
装不上就把报缺的那个也下下来）。

**办法 B**：临时用手机热点 / USB 网卡给路由器供一次外网，装完再切回校园网。

---

## 7. 第五步：在 LuCI 里用

刷新浏览器，左侧菜单 **服务 → RJPA锐捷认证**。界面就**一页**，从上到下分三段：

### ① 运行状态 + 服务类型检测（页面顶部）

运行状态显示进程在不在、PID、日志文件路径和大小。

下面是 **检测服务类型** 按钮：

- 点它会让客户端在后台执行 `rjpa -l`，去认证页面上抓取真实的可选服务类型
- 因为要先探测网关，通常要几秒到几十秒；页面每 1.5 秒轮询一次进度
- **检测完成后，“服务类型”下拉框的候选值会自动更新，不需要刷新页面**
- 抓到的原始输出会显示在按钮下方（万一解析失败，你能直接看到原因）

> 服务类型**不预置候选值**。没检测过时下拉框里只有“自动检测”一项，
> 并提示你先点这个按钮。这是刻意的——不同学校的 eportal 提供的服务类型
> 差别很大，猜不如实测。

### ② 认证设置（页面中间）

- 填 **用户名 / 密码**
- **服务类型**：候选值来自上面的检测结果；选“自动检测”则由程序自己挑第一个
- **手动认证地址**：留空表示自动探测
- **持久化在线**：默认开。断线后每 10 秒自动重连（强烈建议保持开启）
- **日志文件 / 日志上限**
- 勾上 **启用认证**，点 **保存并应用**

保存并应用后配置会通过 `procd_add_reload_trigger` 自动重启服务，不用手动重启。

### ③ 连接日志（页面底部）

- 实时显示后台进程的输出，**默认每 5 秒自动刷新**（可关掉）
- 可以改**显示行数**（默认 200）和**关键字过滤**（比如填 `认证`、`失败`）
- 有 **刷新** 和 **清空日志** 两个按钮
- 滚动条在底部时会自动跟随新日志；你往上翻看历史时不会被打断
- 两个输入框里按回车不会误触发“保存并应用”，只会刷新日志

---

## 8. 日志是怎么串起来的

```
基本设置页底部的日志框（view/rjpa/log.htm）
   │  XHR → /admin/services/rjpa/logdata
   ▼
controller/rjpa.lua  action_logdata()
   │  用 nixio.fs 读文件（不经过 shell，没有注入风险）
   ▼
/var/log/rjpa.log
   ▲
   │  init.d 里: procd_set_param command /bin/sh -c "exec /usr/bin/rjpa ... >>日志 2>&1"
   │
rjpa 进程的 stdout / stderr
```

几个刻意的设计：

- **日志走文件而不是 logd**：文件可控、好过滤，也不会和一堆系统日志混在一起。
  代价是没有时间戳（见第 10.1 节）。
- **`exec`**：`sh -c "exec ..."` 让 shell 把自己替换成 rjpa，这样 procd 跟踪到
  的就是 rjpa 自己的 PID，停止/重启发信号能正确送到，respawn 也正常。
- **密码不做命令拼接**：`shell_quote()` 会把用户名/密码包成 shell 单引号字面量。
  密码里如果有空格、`$`、`;`、`'`，直接拼字符串会被 shell 解释甚至造成命令注入。
- **密码不进系统日志**：启动时只记 `用户=... 服务=... 持久化=...`，不记密码。
- **日志默认放 `/var/log`（内存盘）**：重启就清空，好处是不磨损 flash。
  `log_max_kb`（默认 256KB）超了会自动只保留最后 2000 行；
  启动时和每次读日志时都会检查一次。

---

## 9. 常见问题

### 编译 / 打包阶段（Ubuntu）

**Q: `./build-go.sh: Permission denied`**

```sh
chmod +x build-go.sh build-ipk.sh
```

**Q: `go: command not found`**

```sh
sudo apt update && sudo apt install -y golang-go
go version
```

**Q: `tar: unrecognized option '--zstd'` 或 `zstd: command not found`**

```sh
sudo apt install -y zstd
```

**Q: `make: command not found` / `gcc: command not found`**

```sh
sudo apt install -y make gcc
```

**Q: 在共享文件夹里跑 `make` 报奇怪的权限 / 大小写错误，而且很慢**

SDK 别放共享文件夹。把 SDK 移到虚拟机本地磁盘（`~/sdk`）再打包。
项目源码本身可以留在共享文件夹里。

**Q: `make package/rjpa/compile` 报找不到包**

确认 `build-ipk.sh` 真的把源码拷进去了：

```sh
ls ~/sdk/immortalwrt-sdk-*/package/rjpa/
```

**Q: 想确认包里的文件都对不对**

不用装到路由器上，直接解开看就行。

**`.ipk`（24.10 及更早）—— 它就是一个 ar 包：**

```sh
cd /tmp
ar x ~/rjpa-pkg/dist/rjpa_1.0.0-1_*.ipk
tar tzf data.tar.gz                    # 看装了哪些文件
tar xzOf control.tar.gz ./control      # 看依赖关系
```

**`.apk`（25.12 及以后）—— 它就是带签名的 tar.gz，tar 直接能读：**

```sh
cd /tmp
tar tzf ~/rjpa-pkg/dist/rjpa-1.0.0-r1.*.apk            # 看装了哪些文件
tar xzOf ~/rjpa-pkg/dist/rjpa-1.0.0-r1.*.apk .PKGINFO  # 看元数据（相当于 ipk 的 control）
```

### 路由器阶段

**Q: 菜单里找不到"RJPA锐捷认证"**

1. 确认 `luci-rjpa` 真装上了：`opkg list-installed | grep rjpa`
2. 确认 Lua 支持在：`opkg list-installed | grep luci-compat`。
   缺了就回到第 6 步装 `luci-compat` + `luci-lua-runtime`——
   **这是最常见的原因**，24.10 默认镜像是 JS 版 LuCI，没有这两个包时
   Lua 控制器不会被加载，菜单自然不出现。
3. 清缓存并重启：`rm -f /tmp/luci-indexcache*; /etc/init.d/uhttpd restart`
4. 看有没有报错：`logread | tail -50`

**Q: 页面能打开但一片空白 / 报 `module 'luci.cbi' not found`**

就是缺 `luci-compat`。它的 Makefile 里 `LUCI_DEPENDS:=+luci-lua-runtime`，
所以只要装上 `luci-compat`，Lua 运行时会被一起拉进来。

**Q: 基本设置页下面的日志框一直是"暂无日志"**

按顺序排查：

```sh
/etc/init.d/rjpa status          # 服务在跑吗
cat /var/log/rjpa.log            # 文件里有东西吗
logread | grep rjpa | tail -20   # 系统日志里有没有启停记录
/usr/bin/rjpa -u 学号 -p 密码 -s auto   # 手动前台跑一遍看报什么错
```

服务没起来的常见原因：没勾"启用认证"、用户名/密码为空
（这两种情况 init 脚本会拒绝启动，并在系统日志里留一条记录）。

**Q: 服务反复重启 / 日志里反复出现"请输入认证地址"**

说明自动探测网关失败了。程序在拿不到认证地址且没加 `-l` 时会去读 stdin，
在服务里 stdin 是 EOF，所以它打印一句就退出，然后 procd 又把它拉起来。

解决办法：在"基本设置 → 手动认证地址"里填完整的认证页地址，例如：

```
http://172.17.211.2/eportal/index.jsp?wlanuserip=10.x.x.x&wlanacname=...&nasip=...
```

（浏览器打开认证页，从地址栏整条复制。）

**Q: 认证失败 / 一直连不上**

- 先确认"服务类型"对不对——点页面顶部的"检测服务类型"按钮，或在 SSH 里跑 `rjpa -l`
- 确认账号密码没写错（密码字段是 `password` 类型，保存后不会明文回显，
  但 **LuCI 会把密码读回输入框**，所以你看到的星号是浏览器行为，不是没存上）
- 手动前台跑一遍，日志里的 `响应内容:` 就是认证服务器返回的原文

**Q: 服务类型下拉框里只有"自动检测"一项**

说明还没检测过（缓存 `/tmp/rjpa-services.cache` 不存在），或者路由器重启过
（这份缓存在内存盘，重启即清）。点页面顶部的 **检测服务类型** 按钮跑一次即可。

已经保存进 UCI 的服务类型不会丢——CBI 会把它以"（当前已保存）"的形式加进候选列表，
所以即使不重新检测，原来的配置也能正常保存。

**Q: 点了"检测服务类型"，但解析出来是 0 个**

看按钮下方那段原始输出：

- 输出里是 `未能从认证页面解析到服务类型` → 认证页面是动态加载的，抓不到。
  可以先用 SSH 手动试出正确的值，再在"手动认证地址"里填完整认证地址后重试检测。
- 输出里明明有服务类型却没被解析出来 → 说明 `rjpa -l` 的输出格式变了。
  解析规则在 `controller/rjpa.lua` 的 `parse_services()`，
  认的是「表头行 + 缩进两列」这种格式，改它即可。

**Q: 路由器 flash 不够**

实测 `arm64` 产物 **6.4MB**（mipsle 是 7.4MB），都已经带 `-s -w` 去符号表。
装之前先 `df -h /overlay`。空间紧张的话：

- **用 UPX 压缩**（在 Ubuntu 里压，路由器不需要装 UPX）：
  ```sh
  sudo apt install -y upx-ucl
  upx --best --lzma prebuilt/rjpa-arm64
  ```
  一般能压到原来的 1/3 左右，压出来还是可执行文件、自解压运行。
  但 UPX 偶尔会和 Go 运行时打架，压完**务必先在路由器上手工跑一遍**
  （`/usr/bin/rjpa -l`）确认没问题再打包。
- 挂 U 盘做 extroot，把 overlay 挪到大容量存储上
- 或者二进制单独放 U 盘：`ln -s /mnt/sda1/rjpa /usr/bin/rjpa`

---

## 10. 可选增强

### 10.1 给日志加时间戳

现在日志是 Go 程序的原始 stdout，**没有时间戳**（因为没改 `main.go`）。
想要时间戳，最小改法是把 `fmt` 换成标准库 `log`：

```go
// 1) import 里把 "fmt" 换成 "log"
// 2) 文件里所有 fmt.Println( → log.Println(   fmt.Printf( → log.Printf(
```

改动很机械（`fmt` 在这个文件里只用于输出）。改完重新 `./build-go.sh arm64` 即可，
init 脚本不用动——`log` 默认写到 stderr，而 stderr 已经重定向进日志文件了。

### 10.2 日志持久化 + 定时轮转

想让日志重启后还在，把"日志文件"改成 `/etc/rjpa.log`，
再把"日志上限"调小（比如 128KB），并加一条每天截断的定时任务：

```sh
echo '0 4 * * * tail -n 500 /etc/rjpa.log > /etc/rjpa.log.tmp && mv /etc/rjpa.log.tmp /etc/rjpa.log' \
    >> /etc/crontabs/root
/etc/init.d/cron restart
```

注意 flash 写入寿命，别设太小的间隔。

### 10.3 开机自启确认

```sh
/etc/init.d/rjpa enable      # 勾"启用认证"并保存后其实已经做了
/etc/init.d/rjpa status
```

---

## 11. 替代做法

### 11.1 先手工部署验证（建议第一次走一遍）

打包前想先确认程序在路由器上能跑、页面能显示，可以直接拷文件跳过 opkg：

```sh
# 在 Ubuntu 里
cd openwrt
scp prebuilt/rjpa-arm64           root@192.168.1.1:/usr/bin/rjpa
scp files/etc/config/rjpa         root@192.168.1.1:/etc/config/rjpa
scp files/etc/init.d/rjpa         root@192.168.1.1:/etc/init.d/rjpa

ssh root@192.168.1.1
opkg install luci-compat luci-lua-runtime
mkdir -p /usr/lib/lua/luci/{controller,model/cbi/rjpa,view/rjpa} /usr/share/rpcd/acl.d
chmod +x /usr/bin/rjpa /etc/init.d/rjpa
/etc/init.d/rjpa enable
```

再从 `openwrt/luci-root/usr/...` 对应位置把 5 个 lua/htm 文件 + acl.json
拷到同样的路径下，`/etc/init.d/uhttpd restart`。

这样调通了再走 SDK 打包，能省很多来回。

### 11.2 在 Windows 上编译（可选）

如果哪天想回到 Windows 编 Go 二进制（SDK 打包仍然得在 Linux 做）：

```powershell
cd openwrt
.\build-go.ps1 -List
.\build-go.ps1 -Target arm64
```

产物文件名和 `build-go.sh` 完全一致，两边可以混用。

> **注意**：`build-go.ps1` 必须保存为 **UTF-8 with BOM**。
> Windows PowerShell 5.1 在没有 BOM 时会按 GBK 读 `.ps1`，
> 中文字符串变乱码会把脚本语法搞坏，报一堆"意外的标记"。
> 改坏了就用 VS Code「以 UTF-8 with BOM 保存」，或改用 PowerShell 7（`pwsh`）。

---

## 12. 别人（不同型号）怎么编译

### 12.1 先记住一件事：按「架构」编译，不是按「型号」

`.ipk` 里只有一个 `Architecture` 字段（例如 `aarch64_cortex-a53`），没有型号。
**同一个架构下的所有设备装的是同一个包**：

| 架构 | 覆盖的设备（举例） |
|---|---|
| `aarch64_cortex-a53` | MT7981（小米 AX3000T、360T7）、MT7986（红米 AX6000）、IPQ807x（AX3600、红米 AX6） |
| `mipsel_24kc` | MT7621（新路由3、K2P）、MT7620、MT7628 |
| `mips_24kc` | 老款 Atheros（ath79） |
| `arm_cortex-a7_neon-vfpv4` | 全志 H 系列、部分树莓派 |
| `arm_cortex-a9_neon` | Marvell Armada |
| `x86_64` | x86 软路由 / 虚拟机 |

所以**不需要为每个型号编一份，只需要为每个架构编一份**——6~7 份就覆盖绝大多数设备。

> 另一点容易误解：**SDK 的 target 不必和型号一一对应**，只要架构对得上就行。
> 比如用 `mediatek/filogic` 的 SDK 编出来的 `aarch64_cortex-a53` 包，
> 在 `qualcommax/ipq807x` 的机器上一样能装——因为 `Architecture` 字段相同。
> 我们这个包只依赖 `luci-compat` / `luci-lua-runtime`（都是 `all` 架构的纯 Lua 包），
> 不带任何内核模块依赖，所以跨 target 是安全的。

### 12.2 方式一：不编译，直接用 Release 里的包（推荐给普通用户）

仓库里的 GitHub Actions 会在每次打 tag 时按矩阵自动构建，
把 **`.ipk`（24.10 及更早）和 `.apk`（25.12 及以后）一起**附到同一个 Release 上。

```sh
# 1. 在路由器上查架构和版本
. /etc/openwrt_release; echo "$DISTRIB_RELEASE | $DISTRIB_ARCH"
# 例如输出 24.10.6 | aarch64_cortex-a53

# 2. 按版本挑格式、按架构挑文件
#    24.10.x  →  rjpa_1.0.0-1_aarch64_cortex-a53.ipk
#    25.12.x  →  rjpa-1.0.0-r1.aarch64_cortex-a53.apk
#    两种都要  →  luci-rjpa_1.0.0-1_all.ipk
#                luci-rjpa-1.0.0-r1.apk        （架构无关，各自一份）

# 3. 24.10 及更早
scp rjpa_*.ipk luci-rjpa_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
opkg update && opkg install luci-compat luci-lua-runtime
cd /tmp && opkg install ./rjpa_*.ipk ./luci-rjpa_*.ipk
/etc/init.d/uhttpd restart

# 4. 25.12 及以后
scp rjpa-*.apk luci-rjpa-*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
apk add luci-compat luci-lua-runtime
cd /tmp && apk add --allow-untrusted ./rjpa-*.apk ./luci-rjpa-*.apk
/etc/init.d/uhttpd restart
```

不用装 Go、不用下 SDK、不用编译。

> **版本边界**：`.ipk` 在 **24.10.x 内通用**（我们的包没有版本化依赖、Go 二进制静态链接，
> 用 24.10.6 的 SDK 编出来的在 24.10.0~24.10.6 上都能装）；`.apk` 同理在 25.12.x 内通用。
> 但 **24.10 ↔ 25.12 之间不能互装**——那不是内容问题，是 opkg 和 apk 两种格式不通。

### 12.3 方式二：自己编译（三步）

```sh
# 第 1 步：在路由器上查架构
. /etc/openwrt_release; echo $DISTRIB_ARCH
# 例如 aarch64_cortex-a53

# 第 2 步：编译 Go 二进制 —— 直接把 DISTRIB_ARCH 丢给它，会自动换算
cd openwrt
./build-go.sh aarch64_cortex-a53
#   DISTRIB_ARCH 'aarch64_cortex-a53' -> 编译目标 'arm64'
#   格式校验 : ELF 64-bit LSB executable, ARM aarch64, ...

# 第 3 步：下载同架构的 SDK 并打包（SDK 只要架构对得上就行，见 12.1）
./build-ipk.sh ~/sdk/immortalwrt-sdk-24.10.6-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64
```

`./build-go.sh` 不带参数会打印完整的「目标 ↔ DISTRIB_ARCH」对照表，不用背。

### 12.4 方式三：手工部署（不打包，调试用）

见 [11.1](#111-先手工部署验证建议第一次走一遍)。

### 12.5 维护者：怎么增删 CI 支持的架构

编辑 [`.github/workflows/build-ipk.yml`](../.github/workflows/build-ipk.yml) 里的矩阵。
它是**二维**的：`fmt`（输出格式 × SDK 版本）× `target`（架构），
所以现在是 `2 × 7 = 14` 个 job。

```yaml
        fmt:
          - { name: ipk, ver: '24.10.6' }     # 24.10.x 用 opkg
          - { name: apk, ver: '25.12.2' }     # 25.12.x 用 apk

        target:
          - { name: aarch64-cortex-a53, goarch: arm64, sdk: 'mediatek/filogic', arch: aarch64_cortex-a53 }
```

- `fmt.ver` —— ImmortalWrt 版本。**想跟新版只改这里**；一个 tag 会同时产出两种格式
- `fmt.name` —— `ipk` 或 `apk`，用于 job 名和上传的 artifact 名
- `target.goarch` —— 必须是 `./build-go.sh` 认得的目标（不带参数跑一次就能看到全部）
- `target.sdk` —— ImmortalWrt 的 `target/subtarget`，**只要架构对得上就行**，不必对应型号。
  完整列表：<https://downloads.immortalwrt.org/releases/>
- `target.arch` —— 包元数据里的架构名，用来给 apk 补文件名后缀（apk 文件名本身不带架构）
- 某个 target 下如果没发布 SDK，那一行会**跳过并给出黄色警告**，不会把整行跑红，
  也不影响其他组合
- 想缩短 CI 时间，把 `target` 列表裁到只留你关心的架构即可

架构无关的 `luci-rjpa_*_all.ipk` / `luci-rjpa-*.apk` 每个 job 都会产出一份，
发布时每种格式只取一份，不会重名冲突。

### 12.6 发布一个新版本

```sh
git tag v1.0.1
git push origin v1.0.1
```

workflow 会自动把 `PKG_VERSION` 覆盖成 `1.0.1`（不用手改 Makefile），
构建 14 个组合，全部成功后创建 Release。**任意一个架构失败都会跳过发布**，
不会发出残缺的 Release。

### 12.7 开源前建议再补两样

- **`LICENSE`**：仓库根目录放一个
- **根目录 `README.md`**：现在这份是 `openwrt/` 里的构建手册，
  仓库首页最好放个简短介绍 + 下载指引，再指向这份文档

---

## 附：为什么不用 JS/ucode 写这个界面

可以，而且 24.10 的"原生"做法就是 `htdocs/luci-static/resources/view/*.js` +
`root/usr/share/luci/menu.d/*.json`。但：

- 需求明确要 Lua 模板，Lua 路线在 24.10 确实还能用（第 0 节已核对源码）；
- Lua CBI 写表单比 JS 视图短得多，配置项多的时候更省事；
- 代价是必须让 `luci-compat` + `luci-lua-runtime` 存在，多两个依赖包。

如果哪天升级到 ImmortalWrt 25.12（apk 时代），建议那时候再考虑迁到 ucode/JS。
