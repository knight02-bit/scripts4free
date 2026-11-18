# sysmon.sh — 单机资源快照

> 一条命令看清：**内存用了多少 / GPU 在不在干活 / 谁在吃 CPU 和内存**，并且把每个进程归到它所属的 Docker 容器上（带容器名 + 容器内工作目录 + 宿主机挂载路径）。

首个验证环境：`ncut-3090`（Ubuntu 24.04 / 48 线程 / 2×RTX 3090 / 9 个容器）。

---

## 1. 它解决什么问题

排查这类机器时通常要连敲四条命令，每条都有坑：

| 原来怎么做 | 坑 |
|---|---|
| `free -h` | `used` 和 `available` 语义容易搞混，看不出 cache 该不该算 |
| `nvidia-smi` | 输出长，显存进程是宿主 pid，**不知道属于哪个容器** |
| `ps aux --sort=-%cpu` | `%CPU` 是**生命周期平均值**——跑了 18 天的 Xorg 和刚启动的训练脚本没法比 |
| `docker stats` | 只有容器级汇总，**看不到容器里具体哪个进程在吃**，也没有代码路径 |

`sysmon.sh` 把它们合成一屏，并补上两个关键信息：

1. **CPU% 是瞬时值**（top 二次采样），不是平均值；
2. **容器内进程能定位到容器**——通过 `/proc/<pid>/cgroup` 反查，给出容器名、容器内工作目录、宿主机挂载源。

---

## 2. 快速开始

```bash
# 已部署位置（ncut-3090）
/home/dell/bin/sysmon.sh           # 实际文件
/home/dell/bin/sysmon              # 软链接 → 直接敲 sysmon

# PATH 里还没有 ~/bin 时
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
ln -sf ~/bin/sysmon.sh ~/bin/sysmon     # 或用别名 alias sysmon='~/bin/sysmon.sh'

sysmon 4                                # 验证
```

新机器部署：把 `sysmon.sh` 放到任意目录、`chmod +x` 即可，**不需要安装任何东西**。

---

## 3. 用法

```
sysmon.sh [TOP_N] [--watch [秒]] [--no-color|--color] [--no-docker] [-h|--help] [-V|--version]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `TOP_N` | `8` | ③④ 两张进程表各显示多少行 |
| `--watch N` / `--watch=N` | 关 | 每 N 秒清屏重刷，`Ctrl-C` 退出 |
| `--no-color` / `--color` | 自动 | 输出到终端自动上色，管道/重定向自动关色，可强制 |
| `--no-docker` | 关 | 跳过 ⑤ 容器段与容器反查，耗时从 ~5 s 降到 ~2 s |
| `-h` / `--help` | — | 打印脚本头部用法 |
| `-V` / `--version` | — | 打印版本号 |

常用组合：

```bash
sysmon                          # 日常一眼
sysmon 15                       # 想看长尾进程
sysmon --watch 5                # 盯训练任务起没起来
sysmon --no-docker 12           # 纯主机视角，快
sysmon 12 --no-color > /tmp/snap.txt   # 存证、贴群里
```

---

## 4. 输出详解

```
dell-PowerEdge-R740xd @ 2026-11-18 14:09:06
──────────────────────────────────────────────────────────────
  负载   1.95   (48 线程 →   4.1%)
  运行   19d1h
```

- `负载` = `/proc/loadavg` 一分钟值，括号内是 `load / nproc` 换算的核占比；
- 颜色阈值全脚本统一：**≥60% 黄、≥85% 红**，其余绿。

### ① 内存

```
  总内存 172.5 GiB  已用 9.8 GiB / 172.5 GiB (  5.7%)   可用 162.7 GiB
  缓存   79.4 GiB   swap 已用 0 B / 29.8 GiB
```

`已用 = MemTotal − MemAvailable`；`可用 = MemAvailable`（真正"还能申请多少不触发 swap"）；`缓存 = Buffers + Cached`。

### ② GPU

```
  GPU 型号            显存 已用/总 MiB  利用率  温度  功耗 W      风扇
  0   RTX 3090              276 / 24576      0.0%   35°C   25 / 350      30%
  （显存占用 1%，空闲 24300 MiB）

  显存占用进程:
  5505     258 MiB  [宿主]  /usr/libexec/gnome-remote-desktop-daemon
```

每卡一行（显存/利用率/温度/当前与上限功耗/风扇）+ 一行"显存占用百分比与空闲量"；下方列显存占用进程并标注归属容器。无 `nvidia-smi` 时只打一行提示。

### ③ 占用最高进程（CPU 瞬时）

```
  PID      USER        CPU%   MEM% RSS       运行   命令 / 归属
  2651     root       99.0%   0.1% 205.1 MiB 19d1h    /usr/lib/xorg/Xorg -core :0 -seat seat0 ...
           ↳ [宿主]
  1595547  root        4.9%   1.3% 2.3 GiB   7d21h    /usr/local/bin/python manage.py runserver 0.0.0.0:8001
           ↳ ⚙ geoai-backend /app ↔ /home/dell/geo-sys/Mining-v1/data · /home/dell/geo-sys/Mining-v1/GeoAIBackend
```

字段：`PID` / `USER` / `CPU%`（**瞬时**）/ `MEM%` / `RSS` / `运行`（格式化 3d4h、4h12m）/ 命令行（`/proc/<pid>/cmdline`，截断 88 字符）。

第二行 `↳` 是**归属**，三种形态：

| 形态 | 含义 |
|---|---|
| `[宿主]` | 不在容器里（Xorg、gnome-shell、sshd 等），或容器运行时不可用 |
| `⚙ 容器名 工作目录 ↔ 挂载源…` | 在容器里；`↔` 后是宿主机 bind mount（最多 2 个，已排序） |
| `⚙ 容器名 工作目录 ↔ 镜像 xxx` | 容器无挂载（代码烤进镜像），退化为镜像名 |

若 `top` 缺失或列格式不认识，会多打一行 `⚠ top 不可用…已退化为 ps 平均 CPU%`——此时 CPU% 是平均值，别当瞬时看。

### ④ 占用最高进程（内存）

格式同 ③，按 `RSS` 降序。注意这里的 `CPU%` 来自 `ps`，是生命周期平均值。

### ⑤ 容器

```
  容器                CPU%    内存  镜像                   工作目录 ↔ 宿主路径
  geoai-backend         5.55  1.188GiB  geoai-backend:latest     /app .../model · .../GeoAIBackend · .../data
  dc                    0.27  1.269GiB  datacontroller.jar:latest / （无挂载）
```

> ⚠️ `docker stats` 的内存是 **cgroup 口径**，含该容器 page cache。ollama 这类"模型读过但没在跑"的容器会显示 24 GiB 上下——判断真实占用看 ③④ 的 RSS。

---

## 5. 实现要点

| 机制 | 做法 | 为什么 |
|---|---|---|
| 瞬时 CPU% | `top -bn2 -d 1` 取**第二次**采样 | 批次模式第一帧是自启动以来的平均，必须取第二帧 |
| 列定位 | **解析表头**找 `PID` / `%CPU` 的列号，不写死 `$9` | procps 与 busybox 的列顺序不同；驱动/发行版升级改了列也不会错位 |
| 兜底 | top 缺失或解析为空 → `ps -eo pid,pcpu` 排序，并打印警示行 | 老/精简系统也能出结果，且明确标注口径变了 |
| PID → 容器 | `/proc/<pid>/cgroup` 抓 64 位 id，取前 12 位与 `inspect` 的 `Id` 前缀匹配 | cgroup v1（`/docker/<id>`）与 v2（`docker-<id>.scope`）、rootless 路径都覆盖；不依赖 `docker top` |
| 容器路径 | 一次 `inspect` 批量取 `Config.WorkingDir` + `range .Mounts`，并对挂载排序 | 挂载顺序不保证，排序后两次运行输出一致 |
| 运行时识别 | `docker` 优先，`podman` 次之 | 两者 inspect/stats 模板兼容 |
| 依赖缺失 | `nvidia-smi`、容器运行时都先探测 | 同一份脚本能跑在纯 CPU、无容器的机器上 |
| 数值格式 | `export LC_NUMERIC=C` | 某些 locale 小数点是逗号，会让 `awk` 数值解析错乱（不设 `LC_ALL` 以免破坏中文列宽） |

---

## 6. 依赖与兼容

| 项 | 要求 |
|---|---|
| 解释器 | **bash 4+**（用了关联数组、进程替换、`read <<<`）。`sh sysmon.sh` / `dash` 下会报语法错 |
| 必需 | `ps`、`awk`、`sort`、`grep`、`tr`、`cut`、`head`、`xargs`；`top` 可选（缺失自动退化） |
| 可选 | `nvidia-smi`（无则跳过 ②）、`docker` 或 `podman`（无则 ⑤ 打提示） |
| 内核 | cgroup v1 / v2 均可（Ubuntu 22.04+、Debian 12+ 默认 v2；RHEL 7 是 v1） |
| 权限 | 普通用户可跑；读不到别人 `/proc/<pid>/cmdline` 时退化显示 `comm` 短名，不报错 |
| 终端 | UTF-8 终端显示中文与框线；非 UTF-8 环境会乱码，可 `LC_ALL=C.UTF-8 sysmon` |

---

## 7. 通用性矩阵（实测 / 推断）

| 环境 | 结论 | 依据 |
|---|---|---|
| Ubuntu / Debian / CentOS / RHEL / Alma / Rocky / Fedora / openSUSE / Arch | ✅ 可用 | 纯 procps + /proc + bash，无发行版特定命令 |
| 本机 ncut-3090（Ubuntu 24.04, cgroup v2, 9 容器, 2×3090） | ✅ 已实测 | 正常输出；`--no-docker` 2.2 s |
| 无 GPU 机器 | ✅ 已实测 | ② 打一行"未检测到 nvidia-smi"，其余正常 |
| 无容器运行时的机器 | ✅ 已实测（`PATH` 里摘掉 docker 模拟） | ⑤ 打"未安装 docker/podman"，归属全为 `[宿主]` |
| 没有 `top` 的精简系统 | ✅ 已实测（屏蔽 top 模拟） | 自动退化 ps 平均值并打 ⚠ 提示 |
| `docker` 用 systemd cgroup 驱动（v2 `.scope`）/ cgroupfs / rootless | ✅ 覆盖 | 正则抓 64 位 id，路径形式无关 |
| `podman` 主机 | ⚠️ 按同一 CLI 语义实现，**本机未装，未实测** | inspect/stats 模板与 docker 兼容 |
| WSL2 | ⚠️ 推断可用（有 /proc、procps、docker；GPU 直通时 nvidia-smi 可用，`fan.speed` 为 N/A） | 未实测 |
| BusyBox / Alpine 精简系统 | ⚠️ 部分可用：无 `etimes` 时"运行"列显示 `—`；无 `top` 时退化；`ps -eo` 列名可能不同 | 未实测 |
| macOS | ❌ 不可用 | 无 `/proc`、bash 3.2、BSD `top/ps` 语法不同 |
| Windows 原生（Git Bash 等） | ❌ 不可用 | 无 `/proc`；MSYS 缺 procps |
| Kubernetes / containerd / nerdctl 容器 | ⚠️ 归属显示 `[宿主]` | 只按 docker/podman 的 `ps -q` 建索引，其他运行时的 64 位 id 匹配不上 |
| 内核 `hidepid=2`（进程对其他用户隐藏） | ⚠️ 归属与命令行可能读不到 | 受 `/proc` 挂载选项限制，root 运行则正常 |

一句话：**"任意 Linux 都能跑、缺什么自动降级"，跨平台（macOS/Windows）不通用，容器归属只认 docker/podman。**

---

## 8. 开销与调用频率

单次 **2~5 秒**（`top` 采样固定 1 s；`docker stats` 1.5~4 s 随容器数变化；`--no-docker` 约 2 s）。所以：

- 适合手动巡检、`--watch 5` 以上刷新；
- **不要**放进每秒循环或高频 cron（它自己就带一个 1 秒采样窗口）；
- 想长期留档，用 cron 每分钟追加摘要行，而不是整份输出。

---

## 9. 已知限制

1. 内核线程（`kworker/*`、`kswapd`）`RSS` 显示 `0 B` 属正常——没有用户态内存。
2. 容器名超 18 字符会推挤列宽，不影响数值读取。
3. 同一容器多个进程各占一行，归属相同、不合并。
4. 进程行最多显示 2 个挂载、⑤ 最多 3 个；完整列表：`docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' <c>`。
5. `fan.speed` 在部分驱动/模式下是 `N/A`，该列留空而不报错。
6. 在容器/虚拟机**内部**跑本脚本，`/proc/meminfo` 是宿主口径，与实际可见内存不一致。
7. ⑤ 的 CPU% 来自 `docker stats`，与 ③ 的瞬时值采样窗口不同，数值会有差异。
8. ⑤ 的 `--no-docker` 只省时间，不会改变 ③④ 里 `[宿主]` 的判定（不加载容器索引）。

---

## 10. 排错

| 现象 | 原因 / 处理 |
|---|---|
| `sysmon: command not found` | 文件名是 **`sysmon.sh`**，`~/bin` 里没有 `sysmon` → `ln -sf ~/bin/sysmon.sh ~/bin/sysmon` |
| `syntax error near unexpected token` | 用了 `sh sysmon.sh` / `dash` → 改用 `bash sysmon.sh` |
| `Permission denied` | `chmod +x sysmon.sh` |
| ⑤ 空白 / `未安装 docker/podman` | 运行时不在 PATH，或用户不在 `docker` 组（`sudo usermod -aG docker $USER` 后重新登录） |
| ② 只有一行提示 | `nvidia-smi` 不在 PATH（非交互 SSH 常见），用 `/usr/bin/nvidia-smi` 验证 |
| 中文/框线错位 | 终端字体非等宽中文，或 locale 非 UTF-8；试 `LC_ALL=C.UTF-8 sysmon` |
| ② 显存有占用但进程列表空 | 进程在容器内且当前用户无权读其 cgroup（root 可读），或进程刚退出 |
| ③ 出现 `⚠ … 已退化为 ps 平均` | 该机器没有 procps 的 `top`，或格式不认识；数值口径已改变，不要当瞬时值 |

---

## 11. 在 ncut-3090 上的实测样例

```
dell-PowerEdge-R740xd @ 2026-11-18 14:09:06
  负载 1.95 (48 线程 → 4.1%)     运行 19d1h
① 内存   已用 9.8 GiB / 172.5 GiB (5.7%)   可用 162.7 GiB   swap 0 B
② GPU    0: 276/24576 MiB 0.0% 36°C 33/350W | 1: 12/24576 MiB 0.0% 34°C 28/350W
③ CPU    Xorg 99.0% [宿主] · gnome-shell 62.1% [宿主] · geoai-backend 4.9% ⚙/app
④ 内存   geoai-backend 2.3 GiB · dc 1.2 GiB · ollama 1.1 GiB
⑤ 容器   9 个，活跃内存合计约 1.5 GiB
```

这份快照直接暴露了一个真问题：**Xorg 占满一个核、gnome-shell 再占 0.6 核**——桌面输出走主板板载 VGA（`mgag200`），双 3090 只作 offload sink，合成器只能软件渲染。业务侧（三个矿山容器）合计 1.5 GiB / 7.6% CPU，属严重空载。

---

## 12. 后续可扩展（均未实现）

- `--json`：结构化输出，便于喂监控/告警；
- `--alert`：阈值模式（显存 >90%、某进程 RSS >10 GiB）只输出异常行，适合 cron + 邮件；
- 历史趋势：每次追加一行 CSV（时间/内存/GPU/TOP1），画 24 小时曲线；
- 支持 containerd / nerdctl / K8s：用 `crictl ps` 或 `/run/containerd` 建立 id→名称索引；
- 归属列做成可复制的一列（当前换行缩进会带进去）。

---

## 13. 文件

| 路径 | 说明 |
|---|---|
| `/home/dell/bin/sysmon.sh` | 主脚本（部署位置） |
| `/home/dell/bin/sysmon` | `→ sysmon.sh` 软链接 |
| `/home/dell/bin/sysmon-README.md` | 本文件 |
| `D:\project\MiningSystem\remote\sysmon.sh` | 本地同源副本 |
| `D:\project\MiningSystem\remote\sysmon-README.md` | 本文件副本 |

变更记录：

| 版本 | 变更 |
|---|---|
| 1.0 | 初版：①②③④⑤ 五段；瞬时 CPU；cgroup 反查容器；GPU 进程归属 |
| 1.1 | GPU 表头对齐；挂载路径有序多列；无挂载时显示镜像名；新增 `sysmon` 软链接 |
| 1.2 | 表头驱动定位列号（不再写死 `$9`）；top 缺失自动退化并警示；`--no-docker`；podman 识别；`LC_NUMERIC=C`；`ps` 去掉 `--no-headers/--sort/xargs -r` 等 GNU 专属用法；`etimes` 缺失时降级 |
