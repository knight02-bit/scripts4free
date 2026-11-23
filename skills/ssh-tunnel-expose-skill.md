---
name: ssh-tunnel-expose
description: 用一台有公网 IP 的中转机，把内网机器上的端口通过 SSH 反向隧道暴露到公网，目标机上零新增二进制。适用于被 EDR/AV 盯死、无 sudo、装不了 frp/nps/cloudflared 客户端的机器。Use when the user asks to 内网穿透 / 把内网服务暴露到公网 / 外网访问内网端口 / 端口映射 / 反向隧道 / 公网访问 127.0.0.1 的服务, or when frp/nps/cloudflared binaries on the target keep getting deleted by antivirus.
license: MIT
version: 1.0.0
---

# SSH 反向隧道：把内网端口暴露到公网

```
公网用户 → JUMP_HOST:PUBLIC_PORT ──SSH 反向隧道──→ TARGET_HOST:127.0.0.1:TARGET_PORT
```

全程只用目标机系统自带的 `/usr/bin/ssh`。**目标机上不新增任何文件** —— 这是它相对
frp / nps / cloudflared 的唯一优势，也是最强的优势：EDR、AV、白名单、无 sudo 全部绕过。

## 占位符

| 占位符 | 含义 | 例 |
|---|---|---|
| `TARGET_HOST` | 要暴露服务的机器（通常无公网 IP） | `10.107.0.3` |
| `TARGET_PORT` | 该机器上要暴露的端口 | `8000` |
| `JUMP_HOST` | 有公网 IP、可 SSH 的中转机 | `1.92.104.115` |
| `JUMP_USER` | 登录中转机的用户名 | `root` |
| `PUBLIC_PORT` | 用户最终访问的公网端口 | `8000` |
| `TUNNEL_PORT` | 隧道在中转机上的落地点（冲突时 ≠ PUBLIC_PORT） | `18000` |
| `KEY` | 目标机上的专用密钥 | `~/.ssh/tunnel_ed25519` |

## 第 0 步：三个必查事实（决定整个方案）

不要跳过，跳过必返工。

```bash
# ① 服务真的在跑吗？注意区分 refused 和 timeout
curl -m 5 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:TARGET_PORT/
# connection refused → 本机没进程，先修服务，别做穿透
# timeout            → 中间有墙，查本机防火墙/绑定地址（要 0.0.0.0 不是 127.0.0.1）

# ② 中转机上 PUBLIC_PORT 空闲吗？
ss -tlnp | grep ':PUBLIC_PORT '

# ③ 云安全组 / 防火墙放行了吗？
iptables -L INPUT -n | head          # 或 firewalld / 云控制台
```

**第 ② 条的结果决定走哪条路：**

| PUBLIC_PORT 在 JUMP 上 | 方案 | 复杂度 |
|---|---|---|
| 空闲 | 直接 `-R 0.0.0.0:PUBLIC_PORT:127.0.0.1:TARGET_PORT` | 低，**优先** |
| 被别的服务占着 | `TUNNEL_PORT`（另一空闲端口）+ 加一层 `iptables REDIRECT` | 高 |

为什么优先直绑：少一层 NAT，少一个故障点，也少一条开机要恢复的规则。
只有当端口真的被占、且不能让对方让位时才上 REDIRECT。

## 第 1 步：目标机生成专用密钥

不要用现有的 `id_rsa` / `id_ed25519` —— 出问题不好定位，也不好单独吊销。

```bash
ssh-keygen -t ed25519 -f ~/.ssh/tunnel_ed25519 -N '' -C "tunnel-$(hostname)-$(date +%Y%m)"
cat ~/.ssh/tunnel_ed25519.pub
```

## 第 2 步：中转机加公钥 + 开 GatewayPorts

```bash
# 公钥必须加到「你实际登录的那个用户」名下。
# 加到 alice 却用 root 登录 = Permission denied，这是最常见的失败。
echo '<PUBKEY>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 默认 GatewayPorts no 会把 -R 0.0.0.0:... 静默改绑到 127.0.0.1，外部永远进不来
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
sed -i 's/^#\?GatewayPorts.*/GatewayPorts clientspecified/' /etc/ssh/sshd_config
sshd -t && systemctl reload sshd
sshd -T | grep gatewayports          # 必须回 clientspecified
```

## 第 3 步：目标机起隧道（systemd 用户级 + linger）

```bash
# ~/.config/sshtun-<name>.env
VPS_HOST=JUMP_HOST
VPS_PORT=22
VPS_USER=JUMP_USER
REMOTE_PORT=TUNNEL_PORT
LOCAL_PORT=TARGET_PORT
```

```ini
# ~/.config/systemd/user/sshtun-<name>.service
[Unit]
Description=SSH reverse tunnel: local TARGET_PORT -> JUMP:TUNNEL_PORT
After=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/sshtun-<name>.env
ExecStart=/usr/bin/ssh -NT \
  -p ${VPS_PORT} \
  -i %h/.ssh/tunnel_ed25519 \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=%h/.ssh/known_hosts_tunnel \
  -R 0.0.0.0:${REMOTE_PORT}:127.0.0.1:${LOCAL_PORT} \
  ${VPS_USER}@${VPS_HOST}
Restart=always
RestartSec=20

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now sshtun-<name>.service
loginctl enable-linger "$USER"       # 不登录也要常驻，漏了这行重启后必挂
```

**四个不能省的 ssh 参数**：

| 参数 | 不留会怎样 |
|---|---|
| `ExitOnForwardFailure=yes` | 端口绑定失败时 ssh 只警告不退出，进程活着但隧道是死的 |
| `ServerAliveInterval` + `CountMax` | 网络空闲被中间设备静默掐断，进程还在但已断连 |
| `StrictHostKeyChecking=accept-new` + 独立 `UserKnownHostsFile` | 脚本化时卡在交互提示 |
| `Restart=always` | 一次断线就永久失联 |

> 路径用 `%h` 而不是 `/home/xxx`：systemd 会展开成当前用户家目录，换个机器直接能用。

## 第 4 步：只有 PUBLIC_PORT 被占时才加 REDIRECT

```bash
# JUMP_HOST 上
iptables -t nat -I PREROUTING 1 -p tcp --dport PUBLIC_PORT -j REDIRECT --to-port TUNNEL_PORT
```

持久化（幂等形式，重复执行不会堆规则）：

```bash
# /usr/local/bin/tunnel-nat.sh
#!/bin/bash
add() {
  local p="$1" t="$2"
  iptables -t nat -C PREROUTING -p tcp --dport "$p" -j REDIRECT --to-port "$t" 2>/dev/null \
    || iptables -t nat -I PREROUTING 1 -p tcp --dport "$p" -j REDIRECT --to-port "$t"
}
add PUBLIC_PORT TUNNEL_PORT
```

```ini
# /etc/systemd/system/tunnel-nat.service
[Unit]
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/tunnel-nat.sh
[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload && systemctl enable --now tunnel-nat.service
```

注意：`REDIRECT` 只影响**入站**（PREROUTING）。JUMP 本机访问 `127.0.0.1:PUBLIC_PORT`
仍然打到原来占用它的那个服务，验证时要用 `127.0.0.1:TUNNEL_PORT`。

## 第 5 步：验证（只信两个信号）

```bash
# 信号 ①：JUMP 上 sshd 有没有真的监听
ss -tlnp | grep -E ':(TUNNEL_PORT|PUBLIC_PORT)\b'
# 期望 users:(("sshd",...))，不是别的进程

# 信号 ②：改道规则有没有吃到包
iptables -t nat -L PREROUTING -n -v | grep PUBLIC_PORT
# pkts=0    → 云安全组/防火墙没放行，包在到达本机前就被丢了
# pkts 在涨 → 进来了
```

```bash
# 客户端最终验证
curl -s -o /dev/null -w 'HTTP=%{http_code} size=%{size_download} time=%{time_total}\n' http://JUMP_HOST:PUBLIC_PORT/
```

**三个不可信的测试方法**（踩过的坑，别重复）：

| 方法 | 为什么会骗人 |
|---|---|
| 在目标机上 `nc`/扫描器测公网端口 | 很多企业出口对任意 SYN 都回 SYN-ACK，会报出几千个假 OPEN |
| 用走系统代理的 HTTP 客户端（`Invoke-WebRequest`、默认 curl） | 拿到的是本地代理的 502/407，不是目标的响应 |
| 只看 ssh 进程活没活 | `-N` 模式下进程活着但转发可以已经死了 |

客户端一律用 `curl --noproxy '*'` 或 `Proxy: none`。

## 第 6 步：再接一个端口

同一把密钥可复用，**每个端口一个独立 service**（故障域隔离，一个挂了不影响其他）：

```bash
cp ~/.config/sshtun-a.env ~/.config/sshtun-b.env
# 改 LOCAL_PORT / REMOTE_PORT
cp ~/.config/systemd/user/sshtun-a.service ~/.config/systemd/user/sshtun-b.service
# 改 Description / EnvironmentFile
systemctl --user daemon-reload && systemctl --user enable --now sshtun-b.service
```

REDIRECT 方案则在中转机脚本里多加一行 `add`，然后 `systemctl restart tunnel-nat`。

## 排错速查

| 症状 | 原因 | 处理 |
|---|---|---|
| `Permission denied (publickey,...)` | 公钥加在 A 用户，`VPS_USER` 写 B 用户 | 两边对齐，或把公钥加到目标用户下 |
| `ss` 显示 `127.0.0.1:PORT` 不是 `0.0.0.0` | `GatewayPorts` 没改成 `clientspecified` | 改 sshd_config 后 reload |
| 进程 active 但端口没监听 | 端口被占 + 没开 `ExitOnForwardFailure` | 加参数，然后换端口 |
| 公网 timeout，JUMP 本地能通 | 云安全组没放行 | 控制台加入方向规则 |
| 公网 RST / 立刻断开 | 隧道没立起来 | 看 `ss`，看 `journalctl --user -u sshtun-*` |
| 能用几天后突然不通 | 空闲连接被中间设备掐断 | 确认 `ServerAliveInterval` 生效，`systemctl restart` |
| 重启机器后全挂 | 没 `enable-linger` 或没 `enable` | `loginctl enable-linger`，逐个 `systemctl --user enable` |

## 回滚

按顺序撤，缺一步就留残留：

```bash
# 1. 目标机
systemctl --user disable --now sshtun-<name>.service
rm -f ~/.config/systemd/user/sshtun-<name>.service ~/.config/sshtun-<name>.env
systemctl --user daemon-reload

# 2. 中转机
systemctl disable --now tunnel-nat.service
rm -f /etc/systemd/system/tunnel-nat.service /usr/local/bin/tunnel-nat.sh
systemctl daemon-reload
while iptables -t nat -C PREROUTING -p tcp --dport PUBLIC_PORT -j REDIRECT --to-port TUNNEL_PORT 2>/dev/null; do
  iptables -t nat -D PREROUTING -p tcp --dport PUBLIC_PORT -j REDIRECT --to-port TUNNEL_PORT
done

# 3. 凭据
sed -i '\|tunnel-.*|d' ~/.ssh/authorized_keys     # 只删这一行，别整个清空
rm -f ~/.ssh/tunnel_ed25519 ~/.ssh/tunnel_ed25519.pub ~/.ssh/known_hosts_tunnel

# 4. 密钥登录自测，确认没把别人的路封了
ssh -o BatchMode=yes JUMP_USER@JUMP_HOST 'echo still-ok'
```

## 一句话原则

**能直绑就别 REDIRECT；能隐藏端口就别用默认端口；能改配置就别装软件。**
目标机上唯一该多出来的东西是 `~/.ssh/` 里的两个文件。
