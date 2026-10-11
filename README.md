# RJPA —— 锐捷校园网认证客户端

适用于 **OpenWrt / ImmortalWrt** 的锐捷 eportal 校园网自动认证软件包，
自带 LuCI 网页界面和实时连接日志。

打开路由器后台填个账号密码，它就会自己保持在线；断线了自动重连，出问题能在网页上看日志。

---

## 功能

| 功能 | 说明 |
|---|---|
| **自动获取认证地址** | 探测网关自己找到认证页，不用手工抄 URL |
| **自动检测服务类型** | 从认证页面抓取真实可选的 `service` 值，不用猜、不用试 |
| **LuCI 网页界面** | 填账号密码、看运行状态，全在浏览器里完成 |
| **实时连接日志** | 断线、重连、认证失败都记下来，出问题好排查 |
| **持久化在线** | 断网后自动重连，重试间隔按 20→40→80→…→300 秒退避，不会猛打认证服务器 |
| **命令行也能用** | 没有 LuCI 也能跑：`rjpa -u 学号 -p 密码 -s auto -e` |

**不依赖内核模块**，也没有版本绑定的依赖，所以同一个架构下所有设备共用同一个包。

---

## 支持哪些设备

**一份包通吃同架构的所有设备**——不需要按型号找。下面这些架构已经自动构建好：

| 查到的架构 | 典型设备 |
|---|---|
| `aarch64_cortex-a53` | MT7981（小米 AX3000T、360T7）、MT7986（红米 AX6000）、IPQ807x（AX3600、红米 AX6） |
| `aarch64_generic` | 通用 ARM64（armsr 等） |
| `mipsel_24kc` | MT7621（新路由3、K2P）、MT7620、MT7628 |
| `mips_24kc` | 老款 Atheros（ath79） |
| `arm_cortex-a7_neon-vfpv4` | 全志 H 系列、部分树莓派 |
| `arm_cortex-a9_neon` | Marvell Armada |
| `x86_64` | x86 软路由 / 虚拟机 |

**上面没有你的架构？** 可以自己编译，见 [openwrt/README.md](openwrt/README.md)。

---

## 安装

### 第 1 步：查你的系统版本和处理器架构

SSH 登录路由器，执行这一条：

```sh
. /etc/openwrt_release; echo "$DISTRIB_RELEASE | $DISTRIB_ARCH"
```

输出类似：

```
24.10.6 | aarch64_cortex-a53
```

| 位置 | 含义 | 用来决定 |
|---|---|---|
| 左边 `24.10.6` | 系统版本 | **下载哪种包格式**（见下） |
| 右边 `aarch64_cortex-a53` | 处理器架构 | **去上面的表格里找，决定下载哪个文件** |

> 也可以用 `uname -m` 看 CPU（会输出 `aarch64` / `mips` / `x86_64`），
> 但**选包一定要用 `DISTRIB_ARCH`**——那才是包里的架构名。
> 两者不是一回事：比如 CPU 是 `aarch64`，包架构可能是 `aarch64_cortex-a53`。

### 第 2 步：去 [Releases](../../releases) 下载两个文件

先说格式，**按照第 1 步左边的版本号选**：

| 你的系统版本 | 包管理器 | 下载的文件后缀 |
|---|---|---|
| **24.10 及更早** | opkg | `.ipk` |
| **25.12 及以后** | apk | `.apk` |

然后按架构挑文件（下面以 `aarch64_cortex-a53`、版本 `1.0.1` 举例）：

| 要下载的文件 | 怎么挑 |
|---|---|
| `rjpa_1.0.1-1_aarch64_cortex-a53.ipk`<br>或 `rjpa-1.0.1-r1.aarch64_cortex-a53.apk` | **文件名末尾就是你查到的架构**，照着对 |
| `luci-rjpa_1.0.1-1_all.ipk`<br>或 `luci-rjpa-1.0.1-r1.apk` | 界面包，**架构无关**，所有设备都用同一个 |

一句话：**`rjpa-*` 按架构挑，`luci-rjpa-*` 随便哪个都行。**

### 第 3 步：装上去

**24.10 及更早（opkg）：**

```sh
# 传到路由器
scp rjpa_1.0.1-1_aarch64_cortex-a53.ipk luci-rjpa_1.0.1-1_all.ipk root@192.168.1.1:/tmp/

# 登录路由器安装
ssh root@192.168.1.1
opkg update
opkg install luci-compat luci-lua-runtime        # 必须，见下面常见问题第 1 条
cd /tmp
opkg install ./rjpa_1.0.1-1_aarch64_cortex-a53.ipk ./luci-rjpa_1.0.1-1_all.ipk
/etc/init.d/uhttpd restart
```

**25.12 及以后（apk）：**

```sh
scp rjpa-1.0.1-r1.aarch64_cortex-a53.apk luci-rjpa-1.0.1-r1.apk root@192.168.1.1:/tmp/

ssh root@192.168.1.1
apk add luci-compat luci-lua-runtime             # 必须
cd /tmp
# 本地包没有用路由器的信任密钥签名，所以要加 --allow-untrusted
apk add --allow-untrusted ./rjpa-1.0.1-r1.aarch64_cortex-a53.apk ./luci-rjpa-1.0.1-r1.apk
/etc/init.d/uhttpd restart
```

装完刷新浏览器，左侧菜单 **网络 → 锐捷认证**。

---

## 使用方法

进去只有**一页**，从上到下四段：

**① 运行状态**
显示后台进程在不在、日志文件在哪。

**② 服务类型检测**（第一次用点一下）
点「**检测服务类型**」，客户端会去认证页面抓取真实可选的 `service` 值。
因为要先探测网关，通常几秒到几十秒；完成后下面的「服务类型」下拉框会**自动更新**。

> 服务类型是**实测出来的**，不预置候选值——不同学校提供的值差别很大，猜不如实跑。

**③ 认证设置**
- 填 **用户名 / 密码**（一般就是学号）
- **服务类型**：选「自动检测」就行（程序会取检测到的第一个）
- 勾上 **启用认证**
- 点 **保存并应用** —— 服务会自动重启，不用手动操作

**④ 连接日志**（页面底部）
默认每 5 秒自动刷新，可以调显示行数和关键字过滤，也能一键清空。

正常的日志长这样（只在状态变化时输出，不会刷屏）：

```
持久化模式已开启，每10秒检测一次
网络连接正常
```

断线时会看到：

```
网络已断开，开始尝试重新认证
正在尝试认证...
认证成功！
网络已恢复
```

---

## 命令行用法

不想用网页界面也能直接跑：

```sh
rjpa -u 学号 -p 密码 -s auto -e     # 前台持久化在线
rjpa -l                             # 列出认证页面提供的可选服务类型
rjpa -h                             # 帮助
```

| 参数 | 说明 |
|---|---|
| `-u` | 认证用户名 |
| `-p` | 认证密码 |
| `-s` | 服务类型，默认 `auto`（自动取检测到的第一个） |
| `-m` | 手动指定完整认证地址（自动探测失败时用） |
| `-e` | 持久化模式：断线自动重连 |
| `-l` | 只列出可选服务类型后退出 |
| `-h` | 显示帮助 |

---

## 常见问题

**Q：菜单里找不到「锐捷认证」？**

九成是 `luci-compat` 没装上。24.10 / 25.12 的默认镜像用的是 JS 版 LuCI，
**不带 Lua 兼容层**，而本项目的界面是 Lua 写的，没有它就加载不出来。

```sh
opkg list-installed | grep luci-compat     # 24.10
apk list -I | grep luci-compat             # 25.12
```

缺了就按第 3 步重新装一遍 `luci-compat`，然后：

```sh
/etc/init.d/uhttpd restart
rm -f /tmp/luci-indexcache*
```

**Q：页面能打开但一片空白，或者报 `module 'luci.cbi' not found`？**

同一个原因，装 `luci-compat` 即可（它会自动把 `luci-lua-runtime` 一起拉进来）。

**Q：路由器连不上外网，`luci-compat` 装不了怎么办？**

这是个先有鸡还是先有蛋的问题——认证客户端本身还没跑起来。
可以在电脑上把依赖包下下来，和本软件一起 scp 过去手动装。详细做法和需要的包清单见
[openwrt/README.md](openwrt/README.md) 的第 6 节。

**Q：日志框一直是「暂无日志」？**

按顺序排查：

```sh
/etc/init.d/rjpa status        # 服务在跑吗
cat /var/log/rjpa.log          # 文件里有东西吗
```

服务没起来的常见原因：忘了勾「启用认证」，或者用户名/密码没填（这两种情况会拒绝启动）。

**Q：认证失败 / 一直连不上？**

- 先确认**服务类型**对不对——点页面上的「检测服务类型」重测一次
- 再确认账号密码（密码字段保存后显示为星号是正常的）
- 用 SSH 前台跑一遍，日志里会打印认证服务器返回的原文：

  ```sh
  rjpa -u 学号 -p 密码 -s auto
  ```

**Q：还有别的问题？**

疑难排查、离线安装、自己编译的完整说明都在 **[openwrt/README.md](openwrt/README.md)**。

---

## 自己编译

本项目用 Go 写认证逻辑、用 Lua 写 LuCI 界面，编译需要 OpenWrt SDK。

**完整编译步骤、SDK 下载地址、各架构对照表、排错方法，全部在
[openwrt/README.md](openwrt/README.md)。**

---

## 技术说明（给想改代码的人）

```
main.go              认证逻辑（Go，纯标准库、无 cgo、静态链接）
openwrt/
  Makefile           两个包：rjpa（后台服务）+ luci-rjpa（界面）
  build-go.sh        交叉编译 Go 二进制
  build-ipk.sh       用 SDK 打成 .ipk / .apk
  files/             procd 服务脚本 + UCI 默认配置
  luci-root/         Lua 控制器 / CBI 表单 / 日志视图
```

- **按架构而不是按型号打包**：`.ipk` / `.apk` 里只有 `Architecture` 字段，
  所以 MT7981 和 IPQ807x（同为 `aarch64_cortex-a53`）共用同一个包
- **CI 一次出齐两种格式**：24.10 的 SDK 出 `.ipk`，25.12 的 SDK 出 `.apk`，
  打一个 tag 就都挂在同一个 Release 里
- **界面用的是 LuCI Lua**（`luci-compat` + `luci-lua-runtime`），
  这两个包在 24.10 和 25.12 里都还在

---

## 许可

MIT
