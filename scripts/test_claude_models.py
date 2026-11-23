#!/usr/bin/env python3
import json
import os
import urllib.request
import urllib.error
import time

def test_fetch_claude_models():
    # 1. Đường dẫn file credentials của Claude Code CLI
    cred_path = os.path.expanduser("~/.claude/.credentials.json")
    if not os.path.exists(cred_path):
        print(f"[-] Không tìm thấy file credentials: {cred_path}")
        return

    # 2. Đọc OAuth Token
    with open(cred_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    oauth = data.get("claudeAiOauth", {})
    token = oauth.get("accessToken")
    expires_at = oauth.get("expiresAt", 0)

    print("[+] Đọc thông tin từ ~/.claude/.credentials.json thành công:")
    print(f"    - Access Token: {'***' + token[-8:] if token else 'None'}")
    print(f"    - Expires At (ms): {expires_at} (Hết hạn sau: {(expires_at - time.time()*1000)/1000/3600:.1f} giờ)")

    if not token:
        print("[-] Không tìm thấy accessToken trong file.")
        return

    # 3. Gọi Anthropic API với token OAuth và header beta
    url = "https://api.anthropic.com/v1/models"
    headers = {
        "Authorization": f"Bearer {token}",
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-code/test"
    }

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            res_data = json.loads(resp.read().decode("utf-8"))
            models = res_data.get("data", [])
            print(f"\n[+] Gọi API thành công! Tổng số models khả dụng: {len(models)}")
            print("-" * 80)
            print(f"{'MODEL ID':<30} | {'DISPLAY NAME':<24} | {'CREATED AT'}")
            print("-" * 80)
            for m in models:
                print(f"{m.get('id', ''):<30} | {m.get('display_name', ''):<24} | {m.get('created_at', '')}")
            print("-" * 80)
    except urllib.error.HTTPError as e:
        print(f"[-] HTTP Error: {e.code} {e.reason}")
        print(e.read().decode("utf-8"))
    except Exception as e:
        print(f"[-] Lỗi kết nối: {e}")

if __name__ == "__main__":
    test_fetch_claude_models()
