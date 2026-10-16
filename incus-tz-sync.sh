# Incus-AdminDate

> 让 **Incus** 里的容器/虚拟机时区始终跟宿主机保持一致：
> 新建容器**自动同步** + 一条命令装好常驻服务 + 敲 `admindate` 打开中文菜单做一键检测 / 一键校准。
> 容器侧不挑发行版：Alpine、Debian、Ubuntu、CentOS/Rocky、openSUSE 都能处理。

---

## 🚀 一键安装（Debian / Ubuntu 宿主机）

```bash
curl -fsSL https://raw.githubusercontent.com/CinnieMochi/Incus-AdminDate/main/incus-tz-sync.sh -o /tmp/incus-tz-sync.sh && sudo bash /tmp/incus-tz-sync.sh install
```

这一条命令做完所有事：下载脚本 → 装到 `/usr/local/bin` → 启用**事件守护**（新建/启动容器时立即同步时区）→ 启用**兜底定时器**（每 15 分钟全量校准）→ 创建快捷命令 `admindate`。

装完就能用：

```bash
sudo admindate            # 打开菜单
sudo admindate check      # 一键检测
sudo admindate sync-all   # 一键校准
```

<details>
<summary>没有 curl / 想用 wget / 想手动来</summary>

```bash
# 用 wget
wget -qO /tmp/incus-tz-sync.sh https://raw.githubusercontent.com/CinnieMochi/Incus-AdminDate/main/incus-tz-sync.sh && sudo bash /tmp/incus-tz-sync.sh install

# 连 curl/wget 都没有
apt-get update && apt-get install -y curl

# 手动：clone 或下载后
sudo bash incus-tz-sync.sh install
```
</details>

> ⚠️ `install` 必须**先落成文件**再执行（它要把自己复制到 `/usr/local/bin`）。
> `curl ... | sudo bash` 这种管道形式只能用于只读命令，例如下面的快速体检；直接管道跑 `install` 会给你一条明确的提示而不是报错。

### 只想先看一眼，不想安装

```bash
curl -fsSL https://raw.githubusercontent.com/CinnieMochi/Incus-AdminDate/main/incus-tz-sync.sh | sudo bash -s -- check
```

不落地、不改变任何配置，只列出所有实例的时区和时间差。

---

## 它解决什么问题

LXC 容器和宿主机**共用同一个内核时钟**，所以绝对时间（epoch）本来就是一致的。
你在容器里看到的"时间不对"，几乎全是容器内的**时区配置**和宿主机不一样：

| 发行版 | 时区配置文件 |
| --- | --- |
| Debian / Ubuntu | `/etc/localtime`（符号链接）+ `/etc/timezone` |
| Alpine（busybox/musl） | `/etc/localtime`（符号链接）+ `/etc/TZ` |

本脚本在实例创建/启动时把这几处写成宿主机的时区，并同步 incus 配置里的 `environment.TZ`，
让容器里的进程从启动那一刻就带对时区。

> 顺带一个常被误解的点：**LXC 容器无法拥有独立时钟**（容器内没有任何命令能让它的时间和宿主机不同）。
> 只有 Incus 的**虚拟机**才有时钟独立性，需要靠 VM 内部自己的 NTP。
> 所以 `check` 会同时报"时区"和"时间差 DRIFT"：对容器来说 DRIFT 恒为 0 秒，正好证明问题只在时区。

---

## 界面预览

`sudo admindate`（或 `sudo incus-tz-sync`）打开菜单：

```
============= incus-tz-sync v1.1.0 =============
 宿主机时区 : Asia/Shanghai (CST +0800)
 当前时间   : 2026-01-01 12:00:00
 实例数量   : 3
 事件守护   : active      兜底定时器: active
---------------------------------------------------------
 1) 一键检测所有实例的时区与时间
 2) 一键校准所有实例的时区
 3) 校准单个实例的时区
 4) 安装/启用「新建实例立即同步」(systemd 服务+定时器)
 5) 卸载 systemd 服务与定时器
 6) 查看守护日志(最后 40 行)
 7) 帮助
 0) 退出
请选择: 
```

`check` 的输出：

```
===============================================================================================
宿主机时区: Asia/Shanghai (CST +0800)      宿主机时间: 2026-01-01 12:00:00
===============================================================================================
INSTANCE             STATE    TZ                OFFSET LOCAL-TIME          DRIFT   VERDICT
-----------------------------------------------------------------------------------------------
web                  RUNNING  Asia/Shanghai     +0800  2026-01-01 12:00:00 0s      一致
alpine-tools         RUNNING  UTC               +0000  2026-01-01 04:00:00 -28800s 时区不一致
                     └─ 时区不同
db                   RUNNING  Etc/UTC           +0000  2026-01-01 04:00:00 -28800s 时区不一致
                     └─ 时区不同
old-vm               RUNNING  UTC               +0000  2026-01-01 03:59:52 -28808s 时区不一致
                     └─ 时区不同
                     └─ 这是虚拟机(virtual-machine): 时钟独立于宿主机, 若 DRIFT 不为 0 请在该虚拟机内启用 NTP
cache                STOPPED  -                 -      -                   -       [跳过] 未运行
-----------------------------------------------------------------------------------------------
共 5 个实例: 一致 1, 需处理 3, 未运行/忽略 1
[信息] 执行 'admindate sync-all' 一键校准, 或 'admindate sync <实例名>' 校准单个
```

---

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `sudo admindate` | 打开交互菜单（= `incus-tz-sync menu`） |
| `sudo admindate check` | 一键检测所有实例的时区 / 偏移 / 时间差 / 结论 |
| `sudo admindate sync-all` | 一键校准所有运行中的实例 |
| `sudo admindate sync web` | 只校准 `web` |
| `sudo admindate install` | 安装/更新常驻服务与 `admindate` 命令 |
| `sudo admindate uninstall` | 停用并移除服务、快捷命令（保留配置和日志） |
| `sudo admindate status` | 宿主机时区、实例数量、守护运行状态 |
| `sudo admindate log` | 查看守护日志最后 40 行 |
| `sudo admindate help` | 完整用法 |

常用参数：

```bash
--project <名称>   只处理指定 incus 项目（默认所有项目）
--dry-run          演练：只说明会改什么，不真的改
--force            即使已一致也重写一遍
--quiet            安静模式（适合 cron / systemd）
```

---

## 常驻同步是怎么做到的

`install` 会装上两样东西：

**① 事件守护 `incus-tz-sync.service`（主角）**
常驻运行 `incus monitor --type=lifecycle --format=json`，解析生命周期事件：

| 事件 | 动作 |
| --- | --- |
| `instance-created` | 立刻写 `incus config set <名字> environment.TZ=<宿主机时区>`，容器**第一次启动**时进程就带对时区 |
| `instance-started` / `instance-ready` | 等实例能执行命令后（最多 `READY_TIMEOUT` 秒），写 `/etc/localtime`、`/etc/timezone`、`/etc/TZ` 并复核 |
| 事件流断开 | 2 秒后自动重连；守护启动时先做一次全量校准 |

**② 兜底定时器 `incus-tz-sync.timer`**
每 15 分钟全量校准一次，覆盖"守护进程当时没在跑"的情况。

事件到达即处理，"新建容器"到"时区正确"通常只要 1～2 秒（取决于容器启动速度）。

查看是否在工作：

```bash
sudo admindate log | tail -20      # 应能看到 捕获实例创建/捕获实例启动/同步任务结束
systemctl status incus-tz-sync     # 守护进程状态
```

---

## 兼容任意发行版容器

对容器只有两个要求：能跑 `/bin/sh`、`/etc` 可写。处理顺序：

1. **容器里已有宿主机的 zoneinfo 文件** → 直接建立链接；
2. **容器里没有 tzdata / 没有 `/usr/share/zoneinfo/<时区>`**（Alpine 精简镜像很常见）
   → 用 `incus file push` 把**宿主机自己的** zoneinfo 文件推进容器，再建立链接。
   这一步**不需要容器联网、不需要容器有包管理器**；
3. 可选（默认关闭）：配 `TZ_DATA_INSTALL=1` 才会尝试在容器内 `apk add tzdata` / `apt-get install tzdata`。

写入时覆盖三处，兼容所有主流发行版：

```
/etc/localtime  →  /usr/share/zoneinfo/<宿主机时区>    (Debian/Ubuntu/Alpine/RHEL…)
/etc/timezone                                          (Debian/Ubuntu 系)
/etc/TZ                                                (Alpine / busybox)
```

---

## 配置

`install` 会生成 `/etc/incus-tz-sync.conf`，改完 `systemctl restart incus-tz-sync` 生效：

```sh
HOST_TZ_OVERRIDE=""      # 强制指定宿主机时区(留空=自动探测)
DEFAULT_PROJECT=""       # 只处理某个 incus 项目(留空=所有项目)
IGNORE_CONTAINERS=""     # 忽略名单, 支持通配: "router-*,test"
SET_ENV_TZ=1             # 同时写 incus 配置 environment.TZ
ENFORCE_NAME=1           # 偏移相同但时区名不同时也统一成宿主机的名字
TZ_DATA_INSTALL=0        # 是否允许在容器内装 tzdata(默认从宿主机拷贝, 不联网)
READY_TIMEOUT=120        # 等新实例可执行命令的最长秒数
TIMER_INTERVAL=15min     # 兜底定时器周期
MENU_COMMAND=admindate   # install 时创建的快捷命令(留空=不创建)
LOG_FILE=/var/log/incus-tz-sync.log
```

---

## 升级 / 卸载

**升级**：重跑一次安装命令即可（会覆盖脚本并重启守护，新代码立即生效）：

```bash
curl -fsSL https://raw.githubusercontent.com/CinnieMochi/Incus-AdminDate/main/incus-tz-sync.sh -o /tmp/incus-tz-sync.sh && sudo bash /tmp/incus-tz-sync.sh install
```

**卸载**：

```bash
sudo admindate uninstall      # 停服务、删 systemd 单元、删 /usr/local/bin 里的脚本和 admindate
```

配置文件 `/etc/incus-tz-sync.conf` 和日志 `/var/log/incus-tz-sync.log` 会保留，需要时手动删。

---

## 常见问题

**校准完 `date` 还是旧时间？**
已经跑起来的进程在启动时缓存了时区。容器的**新**进程（新 shell、新服务）立刻就是对的，已运行的服务需要重启才会刷新：

```bash
incus exec 容器名 -- systemctl restart cron    # 或者 incus restart 容器名
```

**`incus exec 容器名 -- date` 对了，但 `timedatectl` 显示不对？**
容器里的 systemd 改不了宿主机时间，`timedatectl` 的 Time zone 行显示宿主机的设定，属正常现象。以 `date` / `/etc/localtime` 为准。

**Alpine 容器 `date` 还是 UTC？**
精简 Alpine 镜像通常没装 tzdata。脚本会自动从宿主机推送 zoneinfo，不依赖容器联网；若推送失败（容器只读 / 磁盘满）会明确报错并返回非 0。

**容器的 `/etc` 只读怎么办？**
会报 `写入时区文件失败(容器内 /etc 可能只读)`。这类容器需要先解除只读（只读挂载 / `security.protection.*`）。

**会不会把我故意设成别的时区的容器改回去？**
会——这正是"保持一致"的含义。例外写法：把实例名（或通配）加进 `IGNORE_CONTAINERS`。

**冻结（Frozen）的容器会卡住脚本吗？**
不会。所有 `incus exec` 都带 `timeout`（默认 20 秒），会被跳过并在下次兜底校准时重试。

**会不会反复折腾我的容器？**
不会。每次校准前先探测，只有确实不一致才写文件；一致就跳过（加 `--force` 才强制重写）。

**`admindate` 提示 command not found？**
`/usr/local/bin` 不在当前 shell 的 PATH 里（少见）。直接用绝对路径 `/usr/local/bin/admindate`，或改用 `sudo incus-tz-sync`。

---

## 测试

仓库带一套行为级测试，用假 `incus` 命令驱动整个脚本，**不会碰你任何真实容器**：

```bash
git clone https://github.com/CinnieMochi/Incus-AdminDate.git
cd Incus-AdminDate && bash test/run-tests.sh
```

覆盖 13 组场景、51 项断言（检测 / 批量校准 / 单实例校准 / dry-run / 项目过滤 / 忽略名单 /
缺 tzdata 的容器 / 旧版 incus 的 CSV 表头兼容 / 写入失败 / 事件守护 / 空列表 / incus 缺失 / 别名调用）：

```
通过 51, 失败 0
```

---

## 环境要求

| 需要 | 说明 |
| --- | --- |
| Debian / Ubuntu 宿主机 | bash 4.4+（Debian 9+ / Ubuntu 18.04+ 都满足） |
| root 权限 | 或 `incus-admin` 组成员 + `sudo` |
| `tzdata` | Debian/Ubuntu 默认已装（取宿主机时区 + 给容器补时区数据） |
| `incus` 命令 | 自动识别 `incus`，找不到会退回 `lxc` |
| systemd | 只有常驻功能需要；没有 systemd 时会提示改用 crontab |

## 已知限制

- **容器时钟无法单独调整**：容器与宿主机共享内核时钟。脚本保证"时区一致"，而"时间差"对容器天然为 0；只有虚拟机才需要（也只能）在 VM 内部用 NTP 自己校准。
- 旧版 incus（不支持 `-f csv,noheader` / `--all-projects`）会自动降级到兼容写法，已用测试覆盖。
- 集群环境：脚本在单个成员上运行，只处理本成员可见的实例。
