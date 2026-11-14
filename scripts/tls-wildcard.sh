#!/usr/bin/env bash
#
# 为 *.pandabase.top 签发/续期一张通配证书，交给宿主 Caddy 静态加载。
#
# 为什么用 acme.sh 而不让 Caddy 自己签：
#   1. 域名未备案，本机 80 被拦截（302 劫持），http-01 不可靠；
#   2. Caddy 官方二进制不带 dnspod 这类 DNS 插件，走 DNS-01 得自己 xcaddy 编，
#      而这台机器上还跑着别的站点，换 Caddy 二进制的风险大于收益。
# 所以：acme.sh 走 DNS-01 签，Caddy 只负责静态加载（deploy/caddy-alt-port.caddyfile）。
#
# 用法（在服务器上，root）：
#   sudo ACME_EMAIL=admin@pandabase.top DP_Id=<id> DP_Key=<key> \
#       bash scripts/tls-wildcard.sh issue
#   sudo bash scripts/tls-wildcard.sh check
#
# DNS 不在 DNSPod 就把 DNS_PROVIDER 换成对应插件名（如 Cloudflare 用 dns_cf，
# 并把凭据换成 CF_Token），插件名见 https://github.com/acmesh-official/acme.sh/wiki/dnsapi
#
# 幂等：证书已存在时 issue 只做续期判定，不重复下单；install 每次都把文件重新落盘。

set -euo pipefail
source "$(dirname "$0")/lib.sh"

ACTION="${1:-issue}"

ACME_EMAIL="${ACME_EMAIL:-}"
DNS_PROVIDER="${DNS_PROVIDER:-dns_dp}"
DOMAIN="${DOMAIN:-pandabase.top}"
WILDCARD="*.${DOMAIN}"
CERT_DIR="${CERT_DIR:-/etc/caddy/certs/${DOMAIN}}"
KEYLENGTH="${KEYLENGTH:-ec-256}"          # 想要 RSA 就设 2048
RELOAD_CMD="${RELOAD_CMD:-systemctl reload caddy}"
ACME_SH="${ACME_SH:-$HOME/.acme.sh/acme.sh}"

install_acme() {
    if [[ -x "$ACME_SH" ]]; then
        return 0
    fi
    need_cmd curl
    info "未找到 acme.sh，安装到 $HOME/.acme.sh"
    curl -fsSL https://get.acme.sh | sh -s "email=${ACME_EMAIL:-}"
    ACME_SH="$HOME/.acme.sh/acme.sh"
    [[ -x "$ACME_SH" ]] || die "acme.sh 安装失败"
}

cert_dir_guard() {
    # 只在 /etc/caddy 下动文件；别的一律拒绝，避免手滑清空别处
    case "$CERT_DIR" in
        /etc/caddy/*) ;;
        *) die "CERT_DIR 必须在 /etc/caddy 下，当前：$CERT_DIR" ;;
    esac
}

show_expiry() {
    local f="$CERT_DIR/fullchain.pem"
    [[ -f "$f" ]] || die "证书不存在：$f（先跑 issue）"
    openssl x509 -in "$f" -noout -subject -enddate
    local end epoch now left
    end="$(openssl x509 -in "$f" -noout -enddate | sed 's/notAfter=//')"
    epoch="$(date -d "$end" +%s)"
    now="$(date +%s)"
    left=$(( (epoch - now) / 86400 ))
    info "剩余 ${left} 天"
    if (( left < 15 )); then
        warn "剩余不足 15 天——续期可能没跑起来，查 $ACME_SH --cron 与 acme.sh 的 crontab"
    fi
}

do_issue() {
    [[ -n "$ACME_EMAIL" ]] || die "需要 ACME_EMAIL（Caddy 的全局 email 与证书到期提醒用同一个）"
    install_acme
    cert_dir_guard

    # 默认 CA 用 Let's Encrypt；通配证书只能走 DNS-01，这里显式指定
    info "签发 ${WILDCARD} + ${DOMAIN}（${DNS_PROVIDER}，DNS-01）"
    if ! "$ACME_SH" --issue --dns "$DNS_PROVIDER" \
            -d "$WILDCARD" -d "$DOMAIN" \
            --keylength "$KEYLENGTH" --server letsencrypt; then
        warn "issue 返回非零——若提示「Domains not changed / Skip」，属正常（已有证书）"
    fi

    mkdir -p "$CERT_DIR"
    info "落盘到 $CERT_DIR 并挂上 reload 钩子"
    "$ACME_SH" --install-cert -d "$WILDCARD" --ecc \
        --key-file       "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --reloadcmd      "$RELOAD_CMD"

    # Caddy 以 caddy 用户运行，私钥不能 world-readable
    chown -R root:caddy "$CERT_DIR" 2>/dev/null || warn "chown root:caddy 失败，检查 caddy 用户是否存在"
    chmod 750 "$CERT_DIR"
    chmod 640 "$CERT_DIR"/*.pem

    show_expiry
    info "续期由 acme.sh 自带的 crontab 负责（每日），reloadcmd 已绑定：$RELOAD_CMD"
}

case "$ACTION" in
    issue) [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "要用 sudo 执行（要写 /etc/caddy/certs 并 reload caddy）"; do_issue ;;
    check) show_expiry ;;
    *) die "未知动作：$ACTION（可用：issue / check）" ;;
esac
