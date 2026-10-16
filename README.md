# incus-tz-sync

让 **Incus 里新建/启动的实例在第一时间把时区对齐到宿主机**，并提供一键检测、一键校准所有实例（或单个实例）的交互菜单。

目标平台：**Debian / Ubuntu 宿主机**（宿主需装好 `incus` 与 `tzdata`；`bash 4.4+`）。
容器侧**不挑发行版**：Alpine、Debian、Ubuntu、CentOS/Rocky、openSUSE……都能处理。

---

## 先回答两个关键问题

**1. "可以实现吗？" —— 可以，而且不需要改动容器镜像。**

**2. 为什么容器时间会和宿主机"对不上"？**

LXC 容器与宿主机**共用同一个内核时钟**，所以绝对时间（epoch）本来就是一致的。
你在容器里看到的时间不同，99% 是因为容器里的**时区配置**和宿主机不一样：

| 发行版 | 时区配置文件 |
| --- | --- |
| Debian / Ubuntu | `/etc/localtime`（符号链接）+ `/etc/timezone` |
| Alpine（busybox/musl） | `/etc/localtime`（符号链接）+ `/etc/TZ` |

所以真正要做的是：**每次实例创建/启动时，把这几个文件写成宿主机的时区**。
脚本就是这么做的，并且顺手把 `incus` 的 `environment.TZ` 配置也写上，让容器里的进程从一启动就带上正确时区。

> 注意：**LXC 容器无法拥有独立的时钟**（没有任何容器内命令能把容器时间改得和宿主机不同）。
> 只有 Incus 的**虚拟机**（`virtual-machine`）才有独立时钟，需要靠 VM 内部自己的 NTP。
> 脚本的 `check` 会同时报告"时区"和"时间差（DRIFT）"：对容器来说 DRIFT 恒为 0 秒，说明时钟没问题，问题只是时区。

---

## 快速开始

```bash
# 1) 把脚本放到宿主机（任意目录），先看看现状
scp incus-tz-sync.sh root@你的VPS:/root/
ssh root@你的VPS
chmod +x /root/incus-tz-sync.sh

# 2) 交互菜单（推荐第一次这样跑）
sudo /root/incus-tz-sync.sh

# 3) 在菜单里选 4) 安装 → 从此新建容器会立即被同步，且每 15 分钟兜底校准一次
#    装好后在任意目录直接敲: sudo admindate
```

菜单长这样：

```
============= incus-tz-sync v1.0.0 =============
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
```

`install` 之后会额外创建一个快捷命令 **`admindate`**，以后在任何目录敲它就直接进菜单：

```bash
sudo admindate            # 等同于 sudo incus-tz-sync menu
```

想换成别的名字：改 `/etc/incus-tz-sync.conf` 里的 `MENU_COMMAND`（留空则不创建），再跑一次 `install`。

---

## 命令行用法

```bash
sudo ./incus-tz-sync.sh check              # 一键检测所有实例
sudo ./incus-tz-sync.sh sync-all           # 一键校准所有实例
sudo ./incus-tz-sync.sh sync web           # 只校准 web
sudo ./incus-tz-sync.sh install            # 安装 systemd 服务 + 兜底定时器 + 快捷命令 admindate
sudo admindate                             # install 之后：任何目录敲这个都直接进菜单
sudo ./incus-tz-sync.sh status             # 查看守护状态 / 实例数量
sudo ./incus-tz-sync.sh log                # 看日志
sudo ./incus-tz-sync.sh uninstall          # 卸载服务
```

`check` 的输出示例：

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
[信息] 执行 'incus-tz-sync.sh sync-all' 一键校准, 或 'incus-tz-sync.sh sync <实例名>' 校准单个
```

> 表里的 `DRIFT` 是**容器时间戳与宿主机时间戳的真实差值（秒）**。
> 对容器它恒为 0；如果它不为 0，说明那是一个虚拟机，或者有人用了非常规的时间命名空间配置。

其它常用参数：

```bash
--project <名称>   只处理指定 incus 项目（默认处理所有项目）
--dry-run          演练：只打印会改什么，不真的改
--force            已一致的实例也重写一遍
--quiet            安静模式（适合 cron / systemd）
```

---

## "第一时间同步"是怎么实现的

`install` 会装上两样东西：

**① 事件守护 `incus-tz-sync.service`（主角）**
它常驻运行 `incus monitor --type=lifecycle --format=json`，解析生命周期事件：

| 事件 | 脚本动作 |
| --- | --- |
| `instance-created` | 立刻写 `incus config set <名字> environment.TZ=<宿主机时区>`，容器**第一次启动**时进程就带对时区 |
| `instance-started` / `instance-ready` | 等实例能执行命令后（最多 `READY_TIMEOUT` 秒），把 `/etc/localtime`、`/etc/timezone`、`/etc/TZ` 写成宿主机时区，并复核 |
| 事件流断开 | 2 秒后自动重连；启动时先做一次全量校准 |

**② 兜底定时器 `incus-tz-sync.timer`**
每 15 分钟全量校准一次，覆盖"守护进程当时没在跑"的情况（可在配置里改周期）。

事件到达时会**立刻**处理，所以"新建容器"到"时区正确"通常只有 1～2 秒（取决于容器启动速度）。

---

## 兼容任意发行版容器

脚本对容器只有两个要求：能跑 `/bin/sh`、`/etc` 可写。处理顺序：

1. **容器内已有宿主机的 zoneinfo 文件** → 直接建立链接；
2. **容器内没有 tzdata / 没有 `/usr/share/zoneinfo/<时区>`**（Alpine 精简镜像很常见）
   → 用 `incus file push` 把**宿主机自己的** zoneinfo 文件推送到容器里，再建立链接。
   这一步**不需要容器联网、不需要容器有包管理器**；
3. 可选（默认关闭）：`TZ_DATA_INSTALL=1` 时才会尝试在容器内 `apk add tzdata` / `apt-get install tzdata`。

写文件时同时覆盖三处，覆盖所有主流发行版：

```
/etc/localtime  →  /usr/share/zoneinfo/<宿主机时区>   (Debian/Ubuntu/Alpine/RHEL…)
/etc/timezone                                         (Debian/Ubuntu 系)
/etc/TZ                                               (Alpine / busybox)
```

另外还会把 `incus` 配置里的 `environment.TZ` 写成宿主机时区，这样即使是"只看环境变量"的程序也能拿到正确时区。
（不想让它改 incus 配置，把配置项 `SET_ENV_TZ=0` 即可。）

---

## 配置文件 `/etc/incus-tz-sync.conf`

`install` 时会自动生成，改完执行 `systemctl restart incus-tz-sync` 生效。

```sh
HOST_TZ_OVERRIDE=""      # 强制指定宿主机时区(留空自动探测)
DEFAULT_PROJECT=""       # 只处理某个项目(留空=所有项目)
IGNORE_CONTAINERS=""     # 忽略名单, 支持通配: "router-*,test"
SET_ENV_TZ=1             # 同时写 incus 配置 environment.TZ
ENFORCE_NAME=1           # 偏移相同但时区名不同也统一成宿主机的名字
TZ_DATA_INSTALL=0        # 是否允许在容器内装 tzdata(默认从宿主机拷贝, 不联网)
READY_TIMEOUT=120        # 等新实例可执行命令的最长秒数
TIMER_INTERVAL=15min     # 兜底定时器周期
MENU_COMMAND=admindate   # install 时创建的快捷命令(留空=不创建)
LOG_FILE=/var/log/incus-tz-sync.log
```

---

## 常见问题

**Q：校准完 `date` 还是旧时间？**
已经跑起来的进程在启动时就把时区缓存下来了。容器内的**新**进程（新的 shell、新的服务）立刻就是正确的；
已运行的服务需要重启才会刷新，例如：

```bash
incus exec 容器名 -- systemctl restart cron      # 或者干脆 incus restart 容器名
```

**Q：`incus exec 容器名 -- date` 显示对了，但 `timedatectl` 显示不对？**
容器里的 systemd 无法修改宿主机时间，`timedatectl` 的 `Time zone` 行会显示宿主机的设定，这是正常的。
以 `date` / `/etc/localtime` 为准。

**Q：容器是 Alpine，`date` 还是 UTC？**
Alpine 精简镜像通常没装 tzdata。脚本会自动从宿主机推送 zoneinfo 文件，不需要容器联网。
如果推送失败（容器磁盘满 / `incus file push` 不可用），会明确报错并返回非 0。

**Q：容器的 `/etc` 只读怎么办？**
脚本会报 `写入时区文件失败(容器内 /etc 可能只读)`。这类容器需要先解除只读（`security.protection.*` / 只读挂载）。

**Q：会不会把我故意设成别的时区的容器改回去？**
会——这正是"保持一致"的含义。例外写法：把实例名（或通配）加进 `IGNORE_CONTAINERS`。

**Q：Frozen（冻结）的容器会卡住脚本吗？**
不会。所有 `incus exec` 都带 `timeout`（默认 20 秒），冻结实例会被跳过并在下次兜底校准时重试。

**Q：循环校准会不会一直去改容器？**
不会。每次校准前先探测，只有确实不一致才写文件；一致就跳过（`--force` 才强制重写）。

---

## 卸载

```bash
sudo ./incus-tz-sync.sh uninstall
```

会停掉并删除 systemd 服务与定时器、删除 `/usr/local/bin/incus-tz-sync`；
配置文件与日志会保留，需要时手动删。

---

## 测试

仓库带了一套行为级测试，用假的 `incus` 命令（`test/mock-incus.sh`）驱动整个脚本：
覆盖检测、批量校准、单实例校准、dry-run、项目过滤、忽略名单、缺 tzdata 的容器、
旧版 incus 的 CSV 表头兼容、写入失败、事件守护、空实例列表、incus 缺失等 12 组场景。

```bash
bash test/run-tests.sh
```

输出形如：

```
通过 46, 失败 0
```

---

## 已知限制

- **容器时钟无法单独调整**：容器与宿主机共享内核时钟。脚本保证"时区一致"，
  而"时间差"对容器天然为 0；只有虚拟机才需要（也只能）在 VM 内部用 NTP 自己校准。
- `bash 4.4+`（Debian 9+/Ubuntu 18.04+ 都满足）。
- 宿主机的 `incus` 版本过老时（不支持 `-f csv,noheader`、`--all-projects`），脚本会自动降级到兼容写法；
  已用测试覆盖。
- 集群环境：脚本在单个成员上运行，只处理本成员可见的实例；`source` 里的实例名解析是集群无关的。
- 用 `curl ... | bash` 这种管道方式执行时 `install` 无法工作（脚本需要自身文件路径），请先保存成文件。
