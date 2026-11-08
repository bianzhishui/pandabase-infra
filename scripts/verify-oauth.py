#!/usr/bin/env python3
"""端到端验证 Casdoor 授权码流程，并用拿到的令牌调一次业务 /mcp。

只依赖标准库。流程：
  1. 起一个回环 HTTP 服务监听已登记的 redirect_uri
  2. 打开浏览器完成登录（PKCE + state）
  3. 用 code 换 access_token，打印 claims
  4. 用该令牌 POST 一次 /mcp：401→令牌没生效；400→令牌已通过校验（握手拒绝空 body）

用法：
  CASDOOR_CLIENT_SECRET='<客户端密钥>' python3 scripts/verify-oauth.py
  CASDOOR_CLIENT_SECRET='...' python3 scripts/verify-oauth.py --no-browser --print-url
"""

from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import http.server
import json
import os
import secrets
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT_SECONDS = 180
RECEIVED: dict[str, str | None] = {}


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def decode_jwt_payload(token: str) -> dict:
    """只 base64 解 payload，不验签——验签是业务服务端的事。"""
    try:
        part = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except Exception:
        return {}


class CallbackHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        expected = urllib.parse.urlparse(ARGS.redirect_uri).path
        if parsed.path != expected:
            self.send_error(404)
            return
        params = urllib.parse.parse_qs(parsed.query)
        RECEIVED["code"] = params.get("code", [None])[0]
        RECEIVED["state"] = params.get("state", [None])[0]
        RECEIVED["error"] = params.get("error", [None])[0]
        RECEIVED["error_description"] = params.get("error_description", [None])[0]

        body = "授权已返回，可以关闭此页面回到终端。".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, *args) -> None:
        pass


def post_form(url: str, fields: dict[str, str]) -> tuple[int, dict]:
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"}
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        raw = exc.read() or b"{}"
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, {"raw": raw[:300].decode(errors="replace")}


def call_mcp(url: str, token: str) -> tuple[int, str]:
    req = urllib.request.Request(
        url,
        data=b"{}",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, resp.read(300).decode(errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, (exc.read(300) or b"").decode(errors="replace")


def main() -> int:
    if ARGS.print_url:
        verifier = secrets.token_urlsafe(64)
        challenge = b64url(hashlib.sha256(verifier.encode()).digest())
        query = urllib.parse.urlencode(
            {
                "client_id": ARGS.client_id,
                "response_type": "code",
                "redirect_uri": ARGS.redirect_uri,
                "scope": ARGS.scope,
                "state": secrets.token_urlsafe(16),
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            }
        )
        print(f"{ARGS.issuer}/login/oauth/authorize?{query}")
        return 0

    secret = os.environ.get("CASDOOR_CLIENT_SECRET") or getpass.getpass("Client Secret: ")
    if not secret:
        print("缺少 client secret", file=sys.stderr)
        return 2

    verifier = secrets.token_urlsafe(64)
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    state = secrets.token_urlsafe(16)

    redirect = urllib.parse.urlparse(ARGS.redirect_uri)
    if redirect.hostname not in {"127.0.0.1", "localhost"}:
        print("脚本只支持回环回调地址", file=sys.stderr)
        return 2

    server = http.server.HTTPServer(
        (redirect.hostname or "127.0.0.1", redirect.port or 80), CallbackHandler
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    query = urllib.parse.urlencode(
        {
            "client_id": ARGS.client_id,
            "response_type": "code",
            "redirect_uri": ARGS.redirect_uri,
            "scope": ARGS.scope,
            "state": state,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        }
    )
    authorize_url = f"{ARGS.issuer}/login/oauth/authorize?{query}"

    print(f"监听 {ARGS.redirect_uri}")
    print(f"授权地址：\n  {authorize_url}\n")
    if not ARGS.no_browser:
        try:
            import webbrowser

            webbrowser.open(authorize_url)
        except Exception:
            pass

    print(f"等待浏览器回调（最长 {TIMEOUT_SECONDS}s）…")
    thread.join(TIMEOUT_SECONDS)
    if thread.is_alive():
        print("超时：没有收到回调。检查 redirect_uri 是否与 Casdoor 里登记的完全一致。", file=sys.stderr)
        return 1

    if RECEIVED.get("error"):
        print(f"授权被拒：{RECEIVED['error']} {RECEIVED.get('error_description') or ''}", file=sys.stderr)
        return 1
    if not RECEIVED.get("code"):
        print("回调里没有 code", file=sys.stderr)
        return 1
    if RECEIVED.get("state") != state:
        print("state 不匹配，丢弃这次结果", file=sys.stderr)
        return 1

    print("拿到 code，换令牌…")
    status, payload = post_form(
        f"{ARGS.issuer}/api/login/oauth/access_token",
        {
            "grant_type": "authorization_code",
            "code": RECEIVED["code"] or "",
            "client_id": ARGS.client_id,
            "client_secret": secret,
            "redirect_uri": ARGS.redirect_uri,
            "code_verifier": verifier,
        },
    )
    print(f"  token 端点 http={status}")
    if status != 200 or "access_token" not in payload:
        print(json.dumps(payload, ensure_ascii=False, indent=2)[:800])
        return 1

    token = payload["access_token"]
    claims = decode_jwt_payload(token)
    print(f"  token_type={payload.get('token_type')} expires_in={payload.get('expires_in')}")
    print(f"  aud={claims.get('aud')}  scope={claims.get('scope')}  sub={claims.get('sub')}")

    print("用该令牌调用 /mcp …")
    code, body = call_mcp(ARGS.mcp_url, token)
    print(f"  http={code}  body={body[:160]}")
    if code in (200, 400, 406):
        print("\n结论：令牌被业务服务接受（400/406 表示握手参数不全，但身份已通过）。")
    elif code == 401:
        print("\n结论：401 —— 令牌未被接受。多半是 aud 不在业务的白名单里。", file=sys.stderr)
        return 1
    else:
        print(f"\n结论：意外状态 {code}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="验证 Casdoor 授权码流程与 /mcp 鉴权")
    parser.add_argument("--issuer", default="https://auth.pandabase.top")
    parser.add_argument("--client-id", default=os.environ.get("CASDOOR_CLIENT_ID", ""))
    parser.add_argument("--redirect-uri", default="http://127.0.0.1:33418/callback")
    parser.add_argument("--scope", default="openid baidu:read")
    parser.add_argument("--mcp-url", default="https://baiduads.pandabase.top/mcp")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--print-url", action="store_true")
    ARGS = parser.parse_args()
    if not ARGS.client_id:
        parser.error("需要 --client-id 或环境变量 CASDOOR_CLIENT_ID")
    sys.exit(main())
