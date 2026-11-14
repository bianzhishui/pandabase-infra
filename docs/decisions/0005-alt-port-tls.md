# ADR 0005：对外入口改用非标端口 8443

- 状态：已接受
- 日期：2026-11-14
- 决策者：项目负责人
- 关联：[ADR 0003](0003-identity-provider.md)（issuer 不可变的例外）、`docs/edge.md`、`docs/contract.md`

## 背景

`pandabase.top` 没有 ICP 备案，而机器在大陆（49.232.229.71）。运营商/云侧的备案拦截
在 7 层看不到明文时下移到 TCP：从 ClientHello 里取明文 SNI，命中「未备案域名 + 大陆 IP」
就对 TCP 直接 RST。所以 443 上的 TLS 握不上手，表现为：

- 客户端 `curl` 返回 000、Python 抛 `SSL: UNEXPECTED_EOF_WHILE_READING`
- 同一台机器上 `curl https://auth.pandabase.top/...` 返回 200（拦截在链路中间，不在服务端）
- 浏览器能打开（走 QUIC/UDP 443，绕开了打在 TCP 上的 RST）

这条拦截**只覆盖常见端口**（80/443 等）。实测同一域名在 8443 上可以正常握手。

问题在于 `docs/contract.md` 把 `https://auth.pandabase.top` 写死为 issuer：它是带主机名的
URL，端口也是它的一部分。所以「换端口」不是纯边缘改动，而是一次 **issuer 变更**——
已签发令牌全部失效，所有客户端重配。ADR 0003 第 2 条说 issuer 不可变，本次是它唯一
被批准的例外，理由与代价都记在这里。

## 决策

1. **对外入口统一到 `:8443`**，443 的站点块保留不删（服务器侧自测、备案后备用）。
2. **issuer 改为 `https://auth.pandabase.top:8443`**（过渡值），`deploy/casdoor/.env` 的
   `CASDOOR_ORIGIN` 与之完全一致。域名备案已在审核中，**通过后按计划切回 443 的无端口 issuer**
   ——那是一次与本次对称的、必须提前排好窗口的迁移（清单见「切回 443」，令牌会第二次失效）。
   在切回之前，8443 是唯一对外入口，不会因为「备案还在审」而变成永久形态。
3. **只开一个端口**。同一端口靠 SNI/Host 分流所有站点，不为每个业务加端口：
   端口数量本身就是暴露面，也是一个要同步到安全组、监控、文档的变量。
4. **证书先沿用 Caddy 托管的那两张 LE 证书**（2027-02-06 到期，本来就是给这两个域名签的），
   8443 站点块不写 `tls` 指令。因为这是过渡态，续期问题大概率不会发生：切回 443 后
   http-01 恢复，Caddy 自动续期。**只有当备案拖到 2027-01 之后**，才启用
   `scripts/tls-wildcard.sh`（acme.sh + DNS-01 + 静态加载）顶过到期日——届时把
   `deploy/caddy-alt-port.caddyfile` 里注释掉的 `tls` 行打开即可。
5. **容器仍只绑回环**，公网入口只有宿主 Caddy。本次不改动 `127.0.0.1:8000/8001/8002`
   的绑定，也不改「反代不做鉴权」的边界。

## 被否决的方案

| 方案 | 否决理由 |
|---|---|
| **IP + 端口**（`https://49.232.229.71:8443`） | 两个硬伤：① 丢 Host 分流，Casdoor 不支持子路径挂载，只能「一服务一端口」，端口爆炸；② 公网 IP 证书只有 160 小时有效期，且 Caddy 对 IP 标识的支持仍有 bug（[caddyserver/caddy#7399](https://github.com/caddyserver/caddy/issues/7399)），得靠 acme.sh 签 + 每 6 天续期，续期失败即 6 天内全断。相比本方案多一份脆弱性，换不到任何收益 |
| 自签证书 / 私有 CA | Claude、Cursor 这类公网客户端装不了我们的根证书 |
| 境外 VPS 终止 TLS + WireGuard 回源 | 唯一能保住 issuer 与客户端零改动的做法，但要常驻第二台机器、破掉「单机 2C2G」的规模假设，还得管跨境链路的可用性。留作 8443 也被封时的退路 |
| 明文 HTTP（`http://域名:8080`） | OAuth 令牌与登录 Cookie 全裸奔；`http` 的 302 劫持拦截还不分端口 |
| 买/借一个已备案域名 | 备案主体不是自己，随时被注销；且仍是换域名 = 换 issuer |
| xcaddy 编带 `caddy-dns/dnspod` 的 Caddy，用自动 ACME | 可行，但这台共享宿主机上还跑着别的站点，换 Caddy 二进制的风险大于「acme.sh 签 + 静态加载」 |

## 后果

### 正面

- 不加机器、不花钱，一天内可用
- 证书仍是 90 天自动续期，运维方式与「证书快到期看 openssl」那套习惯不变
- 只多开一个端口，安全组/防火墙的变量最少
- 443 站点块保留，任何时刻都能一键回退

### 负面 / 需要承担

| 风险 | 说明 | 缓解 |
|---|---|---|
| 客户端全部要改 URL | Claude/Cursor/VS Code 的 connector、每个业务的 issuer/JWKS/RESOURCE_URL | 迁移清单一次做完，见下节 |
| 已发令牌全部失效 | `iss` 变了，JWKS 不匹配 | 客户端重新授权；这就是 ADR 0003 第 2 条要提前定死域名的原因 |
| 非标端口兼容性 | 少数 OAuth 客户端/网关会拒绝带端口的 issuer，或把默认端口写死 | 迁移后逐个客户端实测；不接受的一方改用 SSH 隧道或本地代理 |
| 8443 哪天也被封 | 拦截规则会演进 | 监控「握手失败」；真发生就转境外 VPS 回源，不要再换端口 |
| 备案通过后要再迁一次 | 令牌第二次失效 + 客户端第二次重配 | 切回做成清单化操作（见「切回 443」），选低峰窗口一次做完；切回后 issuer 恢复无端口，与所有历史文档一致 |

## 一次性迁移清单

顺序不能反（先开口和证书，再改 issuer，最后改业务与客户端）：

1. 安全组/轻量防火墙放通 **8443/TCP**
2. `sudo ACME_EMAIL=... DP_Id=... DP_Key=... bash scripts/tls-wildcard.sh issue`
3. 追加 `deploy/caddy-alt-port.caddyfile` 到 `/etc/caddy/Caddyfile` → `caddy validate` → `reload`
4. 服务器侧验证：`curl -fsS https://auth.pandabase.top:8443/.well-known/openid-configuration`
5. `deploy/casdoor/.env` 的 `CASDOOR_ORIGIN` 改 `https://auth.pandabase.top:8443`，重建 Casdoor
6. 逐个业务仓库改 `CASDOOR_ISSUER` / `JWKS_URL` / `RESOURCE_URL`（跨仓，先 infra 后业务）
7. 客户端换 MCP URL，重新授权；跑 `scripts/verify-oauth.py` 收口
8. 回填 `docs/contract.md`、`docs/workload-onboarding.md` 的登记表

回滚：删掉 8443 站点块 + `CASDOOR_ORIGIN` 改回旧值 + `systemctl reload caddy`。
旧 issuer 仍在 Git 里，但令牌同样会再废一次。

## 重新评估条件

- **备案审核通过（已确定会发生，不是「条件」）→ 按「切回 443」执行，本 ADR 随之失效于边缘层**
- 备案比预期拖到 2027-01 之后 → 先临时做 DNS-01 续期（见实施记录遗留 1），再等切回
- 8443 上开始出现 SNI-RST（转境外 VPS 回源，见上表）
- 要对接公开生态（第三方 OAuth 客户端、应用市场、对外 API 目录）——带端口的 issuer 与
  未备案状态都不适合当门面
- 业务数 ≥ 5 且需要把入口交给 CDN/WAF

## 实施记录（2026-11-14，pandabase-dev01 / 49.232.229.71）

实测的三条事实（决定了下面每一步为什么这么做）：

- `:80` → `302 Location: https://dnspod.qcloud.com/static/webblock.html?d=<域名>`，DNS 层没坏，
  是备案拦截页；因此 **http-01 永久不可用**
- `:443` → ClientHello 后 RST（`openssl s_client` 报 `unexpected eof while reading`）；**tls-alpn-01 也不可用**
- `:8443` → 握手正常、证书校验通过

已做的改动（全部留了 `.env.bak-<时间戳>` / `Caddyfile.bak-<时间戳>`）：

1. `/etc/caddy/Caddyfile` 追加 `auth.pandabase.top:8443` 与 `baiduads.pandabase.top:8443` 两个站点块
2. `deploy/casdoor/.env`：`CASDOOR_ORIGIN=https://auth.pandabase.top:8443`，重建容器
3. `casdoor` 库 `application.redirect_uris`：`https://auth.pandabase.top/apps` → 带 `:8443`
   （Casdoor 自己那条跳转，不加端口会把用户带回被拦的 443）
4. `/opt/mybmo-mcp/deploy/.env`：`CASDOOR_ISSUER` / `MYBMO_JWKS_URL` / `MYBMO_RESOURCE_URL` 加端口，重建容器

**证书这一步与上文决策不同，是分两段的**：Caddy 里本来就有这两张仍在有效期内的 LE 证书
（到期 2027-02-06，ARI 续期窗口 2027-01-06~08），所以当天没有签新证书，两个站点块
**暂不写 `tls` 指令**，直接用 Caddy 托管的证书。S 段（DNS-01 + 静态加载）在上表的
「遗留」第 1 条之前完成即可，切换时只需打开 `deploy/caddy-alt-port.caddyfile` 里注释掉的
`tls` 行。

验收（从中国移动家宽侧发起的真实链路）：

```text
issuer   = https://auth.pandabase.top:8443
jwks     = https://auth.pandabase.top:8443/.well-known/jwks
healthz  = 200      mcp 无令牌 = 401      dbx 网关 = 401
证书      = CN=auth.pandabase.top, 2026-11-08 → 2027-02-06, 校验结果 0
```

遗留（按紧急度）：

1. **证书续期必须走 DNS-01**，需要 DNSPod API 凭据（`DP_Id` / `DP_Key`）。不落实则
   2027-02-06 之后两个站点整体不可用，且没有 http-01/tls-alpn-01 兜底
2. `MYBMO_BAIDU_CALLBACK_URL` 仍是 `https://baiduads.pandabase.top/oauth/baidu/callback`：
   百度服务器回调也走公网，443 一样被拦。改值必须与「百度开放平台」后台登记的回调地址
   同时改，否则会从「连不上」变成「回调地址不匹配」
3. 业务仓库（`mybmo-mcp`）自己的 `README.md`、`docs/auth-contract.md`、`.env.example`
   仍是旧值；本次只改了服务器上的 `deploy/.env`，源码侧待该仓库自己同步
4. 各 MCP 客户端（Claude Code / Cursor / VS Code）的 connector URL 需重配并重新授权

## 切回 443（备案审核通过后执行，一次做完，约 30 分钟）

前置判断（**先验、后切**，别凭日子猜）：备案通过后腾讯云的拦截解除可能有几小时延迟，
所以在 443 上先跑这一条，通了再动配置：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://auth.pandabase.top/.well-known/openid-configuration   # 期望 200
echo | openssl s_client -connect auth.pandabase.top:443 2>/dev/null | openssl x509 -noout -dates          # 期望出证书
```

注意 443 的站点块一直在（`deploy/caddy-site.caddyfile`），所以这两条现在就该通——不通说明拦截还在。
**切之前不必抢时间**：443 空着没有代价，挑一个客户端都在线、你手边有空的窗口更好。

1. `/etc/caddy/Caddyfile`：删掉两个 `:8443` 站点块（保留备份），`caddy validate` → `reload`
2. `deploy/casdoor/.env`：`CASDOOR_ORIGIN=https://auth.pandabase.top`（去掉 `:8443`），重建 Casdoor
3. `casdoor` 库 `application.redirect_uris`：`https://auth.pandabase.top:8443/apps` → 去掉端口
4. `/opt/mybmo-mcp/deploy/.env`：`CASDOOR_ISSUER` / `MYBMO_JWKS_URL` / `MYBMO_RESOURCE_URL` 去掉端口，重建容器
5. 客户端 URL 改回不带端口，重新授权；`scripts/verify-oauth.py` 用默认 `--issuer` 即可
6. 验收：discovery 的 `issuer` 无端口、`/healthz` 200、`/mcp` 401
7. 端口收口：安全组关掉 8443（少一个暴露面）；`deploy/caddy-alt-port.caddyfile` 留在仓库里备查
8. 文档：本 ADR 标「已被切回取代」，`docs/contract.md` / `README` / `docs/edge.md` 的值去掉端口

**不需要重新签证书**：Caddy 托管的那两张 LE 证书（2027-02-06 到期）本来就是给这两个域名签的，
切回 443 后 Caddy 恢复自动续期（http-01 重新可用），DNS-01 那条路可以完全不做——
除非备案拖到 2027-01 之后。
