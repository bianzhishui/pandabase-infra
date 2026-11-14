# 边缘：域名、TLS 与反向代理

线上形态是**共享宿主机**：宿主已有 Caddy（systemd 托管）在 80/443 上服务别的站点，
本平台不另起 Caddy 容器，只用站点片段接入。

## 一、拓扑与对外入口

**对外入口是 `:8443`，不是 443。** `pandabase.top` 未备案，而机器在大陆：中间设备会从
ClientHello 的明文 SNI 认出未备案域名，在 443 上直接 RST，TLS 握不上手（症状：客户端
`curl` 返回 000、Python 抛 `UNEXPECTED_EOF_WHILE_READING`，而服务器侧 `curl` 却 200、
浏览器走 QUIC 又能开）。拦截只覆盖常见端口，因此对外入口挪到 8443，见
[ADR 0005](decisions/0005-alt-port-tls.md)。

443 上的站点块**保留不删**，只用于服务器侧自测与备案完成后的切回；客户端一律走 8443。

```text
公网 ──:8443──▶ 宿主 Caddy（systemd，按 SNI/Host 分流）
                 ├ auth.pandabase.top:8443     → 127.0.0.1:8001   Casdoor
                 └ baiduads.pandabase.top:8443 → 127.0.0.1:8000   业务（mybmo-mcp）

            :443 ─▶ 同一批站点（保留，仅服务器侧自测；客户端不要用）
```

| 组件 | 监听 | 暴露面 |
|---|---|---|
| 宿主 Caddy | `*:80`、`*:443`、`*:8443` | 公网（对外只用 8443） |
| 业务容器 | `127.0.0.1:8000` | 仅回环 |
| Casdoor | `127.0.0.1:8001` | 仅回环（管理台） |
| DBX 控制台 | `127.0.0.1:8002` | 仅回环（SSH 隧道；**不接 Caddy**，见 `docs/dbx.md`） |
| DBX MCP | `https://auth.pandabase.top:8443/api/server/built-in/dbx` | 公网，但先过 Casdoor 登录与工具白名单（只读） |
| PostgreSQL | 容器网络内 `5432`；宿主 `127.0.0.1:5432` | 仅回环（SSH 隧道 / DBX 用，公网不可达） |

## 二、接入一个站点

把 `deploy/caddy-alt-port.caddyfile` 里对应的块追加到 `/etc/caddy/Caddyfile`：

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-$(date +%F)
sudo tee -a /etc/caddy/Caddyfile < deploy/caddy-alt-port.caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Caddy 的全局 `email` 只能出现在文件最前面；宿主配置里没有的话，加一个全局块收证书到期提醒。

新业务复制 `baiduads` 那段，只改域名与上游端口，**端口一律 8443**——同一端口靠 SNI/Host
分流，安全组只需要放通这一个口。

## 三、四条不能改的约束

1. **反代不做鉴权。** 让 Caddy 注入 `X-User` 头、应用信任它，等于留一条直连回环即可伪造的旁路。
   业务必须自己校验 Bearer 令牌。
2. **反代不能缓冲。** Streamable HTTP 依赖即时刷新；Caddy 的 `reverse_proxy` 默认不缓冲，
   换 nginx 必须显式关 `proxy_buffering` 并调 `proxy_read_timeout`，否则表现为「连上了但一动不动」。
3. **`/healthz` 不鉴权。** 容器 HEALTHCHECK、外部监控、排障都要能直接打到；它不返回账户与令牌。
4. **DBX UI 不接公网；DBX MCP 只经 Casdoor 网关。** UI 只有共享口令、没有 OIDC 与审计，
   只绑 `127.0.0.1:8002`，通过 SSH 隧道访问；不要给它加站点块。MCP 入口是
   `auth.pandabase.top:8443/api/server/built-in/dbx`，由 Casdoor 校验令牌并注入上游 token，
   见 `docs/decisions/0004-dbx-console.md`。

## 四、证书

- **现状（2026-11-14）**：两个 8443 站点不写 `tls` 指令，直接用 Caddy 自己托管的同名 LE 证书
  （`/var/lib/caddy/.local/share/caddy/certificates/`，到期 2027-02-06）。那天证书还在有效期内，
  没必要为了换端口重新签一张。
- **但续期必须换机制**：`http-01` 依赖 80、`tls-alpn-01` 依赖 443，而这两个口正是被备案拦截的地方
  （80 返回 302 到 `dnspod.qcloud.com` 拦截页，443 直接 RST）。所以到期前必须改成 **DNS-01**：
  `scripts/tls-wildcard.sh` 用 acme.sh 签 `*.pandabase.top` 到 `/etc/caddy/certs/pandabase.top/`，
  再把 `deploy/caddy-alt-port.caddyfile` 里注释掉的 `tls` 行打开。
- 切换后：有效 90 天，acme.sh 自带 crontab 每日续期，续期后自动 `systemctl reload caddy`。
- **这是过渡态**：备案审核通过后按 ADR 0005「切回 443」回到标准入口，那时 Caddy 的自动续期恢复，
  DNS-01 可以完全不做。只有当备案拖到 2027-01 之后，才需要先补 DNS-01 顶过 2027-02-06。
- 查到期：

  ```bash
  sudo bash scripts/tls-wildcard.sh check
  # 或
  echo | openssl s_client -connect auth.pandabase.top:8443 2>/dev/null | openssl x509 -noout -dates
  ```

- 证书失败先看 `sudo ~/.acme.sh/acme.sh --cron` 与 `journalctl -u caddy -f`，不要动容器。
- 通配证书要求 DNS 里有记录才好排障——**通配符不等于有记录**，站点域名仍需各自有 A 记录。

## 五、专用宿主机（备用形态）

整台机器只服务本平台时，改用容器版：`docker compose --profile dedicated` + `deploy/Caddyfile`。
两种形态不要叠加（不要在容器 Caddy 前面再放一层宿主 Caddy）。

该形态仍在 443 上，**只适用于机器在境外或域名已备案的情况**；在大陆未备案的机器上，
按 `deploy/caddy-alt-port.caddyfile` 的思路把站点地址加上 `:8443` 并静态加载证书。
