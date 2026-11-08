# 边缘：域名、TLS 与反向代理

线上形态是**共享宿主机**：宿主已有 Caddy（systemd 托管）在 80/443 上服务别的站点，
本平台不另起 Caddy 容器，只用站点片段接入。

## 一、拓扑

```text
公网 ──:443──▶ 宿主 Caddy（systemd）
                 ├ baiduads.pandabase.top → 127.0.0.1:8000   业务（mybmo-mcp）
                 └ auth.pandabase.top     → 127.0.0.1:8001   Casdoor
```

| 组件 | 监听 | 暴露面 |
|---|---|---|
| 宿主 Caddy | `*:80`、`*:443` | 公网 |
| 业务容器 | `127.0.0.1:8000` | 仅回环 |
| Casdoor | `127.0.0.1:8001` | 仅回环（管理台） |
| PostgreSQL | 容器网络内 `5432`；宿主 `127.0.0.1:5432` | 仅回环（SSH 隧道 / DBX 用，公网不可达） |

## 二、接入一个站点

把 `deploy/caddy-site.caddyfile` 里对应的块追加到 `/etc/caddy/Caddyfile`：

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-$(date +%F)
sudo tee -a /etc/caddy/Caddyfile < deploy/caddy-site.caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Caddy 的全局 `email` 只能出现在文件最前面；宿主配置里没有的话，加一个全局块收证书到期提醒。

## 三、三条不能改的约束

1. **反代不做鉴权。** 让 Caddy 注入 `X-User` 头、应用信任它，等于留一条直连回环即可伪造的旁路。
   业务必须自己校验 Bearer 令牌。
2. **反代不能缓冲。** Streamable HTTP 依赖即时刷新；Caddy 的 `reverse_proxy` 默认不缓冲，
   换 nginx 必须显式关 `proxy_buffering` 并调 `proxy_read_timeout`，否则表现为「连上了但一动不动」。
3. **`/healthz` 不鉴权。** 容器 HEALTHCHECK、外部监控、排障都要能直接打到；它不返回账户与令牌。

## 四、证书

- Let's Encrypt，自动续期；到期时间可用 `echo | openssl s_client -connect auth.pandabase.top:443 2>/dev/null | openssl x509 -noout -dates` 查
- 子域必须先在 DNS 里有 A 记录，否则 Caddy 会反复重试签发并失败——**通配符不等于有记录**
- 证书失败看 `journalctl -u caddy -f`，不要动容器

## 五、专用宿主机（备用形态）

整台机器只服务本平台时，改用容器版：`docker compose --profile dedicated` + `deploy/Caddyfile`。
两种形态不要叠加（不要在容器 Caddy 前面再放一层宿主 Caddy）。
