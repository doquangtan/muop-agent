#!/usr/bin/env python3
"""Thử nghiệm các phương thức JSON-RPC của `agy acp` (Agent Client Protocol, stdio).

Chạy: python3 server/scripts/acp_probe.py [--app-data-dir antigravity] [--cwd DIR] [--timeout 30]
      [--with-prompt "câu hỏi"]

Mặc định KHÔNG gọi:
- `logout` (xóa đăng nhập agy; kiểm tra tay bằng cách gửi phương thức đó trong client của bạn);
- `session/prompt` (tốn quota model) — chỉ chạy khi truyền `--with-prompt`.

Mỗi phương thức in một dòng: OK / LỖI (mã + thông điệp) / KHÔNG PHẢN HỒI, kèm tóm tắt kết quả.
Không in token hay nội dung đăng nhập. Phiên tạo ra được đóng ở cuối.
"""

from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import time


class AcpClient:
    def __init__(self, agy: str, app_data_dir: str, cwd: str, log_path: str | None):
        cmd = [agy, "acp", "--app-data-dir", app_data_dir]
        if log_path:
            cmd += ["--log-file", log_path]
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            cwd=cwd,
        )
        self.next_id = 1
        self.notifications: list[dict] = []

    def _read_line(self, timeout: float) -> str | None:
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        if not ready:
            return None
        line = self.proc.stdout.readline()
        return line if line else None

    def request(self, method: str, params: dict | None, timeout: float) -> dict | None:
        """Gửi một request và đợi đúng phản hồi có cùng id. Trả None nếu hết giờ."""
        req_id = self.next_id
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": req_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = self._read_line(min(0.5, max(0.0, deadline - time.time())))
            if line is None:
                if self.proc.poll() is not None:
                    return None
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            if data.get("id") == req_id and ("result" in data or "error" in data):
                return data
            if "method" in data and "id" not in data:
                self.notifications.append(data)
        return None

    def notify(self, method: str, params: dict) -> None:
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def close(self) -> None:
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def summarize(value, limit: int = 160) -> str:
    text = json.dumps(value, ensure_ascii=False)
    return text if len(text) <= limit else text[: limit - 3] + "..."


def report(results: list, name: str, reply: dict | None, detail_fn=None) -> dict:
    if reply is None:
        status, detail = "KHÔNG PHẢN HỒI", ""
    elif "error" in reply:
        err = reply["error"]
        status = "LỖI"
        detail = f"{err.get('code')} {err.get('message', '')}"
    else:
        status = "OK"
        detail = detail_fn(reply.get("result")) if detail_fn else summarize(reply.get("result"))
    print(f"{name:26s} {status:14s} {detail}")
    results.append({"method": name, "status": status, "detail": detail})
    return reply or {}


def main() -> int:
    ap = argparse.ArgumentParser(description="Thử nghiệm các phương thức ACP của agy")
    ap.add_argument("--agy", default="agy", help="đường dẫn lệnh agy (mặc định: agy trong PATH)")
    ap.add_argument("--app-data-dir", default="antigravity")
    ap.add_argument("--cwd", default=os.path.expanduser("~"))
    ap.add_argument("--timeout", type=float, default=30.0, help="giây chờ mỗi phương thức")
    ap.add_argument("--with-prompt", metavar="TEXT", help="gửi session/prompt (tốn quota model)")
    ap.add_argument("--log-file", help="ghi log của agy acp vào file này")
    args = ap.parse_args()

    client = AcpClient(args.agy, args.app_data_dir, args.cwd, args.log_file)
    results: list[dict] = []
    t = args.timeout
    print(f"agy acp  app-data-dir={args.app_data_dir}  cwd={args.cwd}")
    print("-" * 100)
    try:
        init = report(
            results,
            "initialize",
            client.request(
                "initialize",
                {"protocolVersion": 1, "clientCapabilities": {}},
                t,
            ),
            lambda r: f"{r.get('agentInfo', {}).get('name')} {r.get('agentInfo', {}).get('version')} "
            f"caps={sorted((r.get('agentCapabilities') or {}).keys())} "
            f"auth={[m.get('id') for m in r.get('authMethods', [])]}",
        )
        if "error" in init or "result" not in init:
            print("initialize thất bại, dừng.")
            return 1

        auth_method = "oauth-personal"
        report(
            results,
            "authenticate",
            client.request("authenticate", {"methodId": auth_method}, t),
            lambda r: summarize((r or {}).get("_meta", {}).get("antigravity", {}).get("tier", r), 200),
        )

        new_reply = report(
            results,
            "session/new",
            client.request("session/new", {"cwd": args.cwd, "mcpServers": []}, t),
            lambda r: f"sessionId={r.get('sessionId')} models={len(r.get('models', {}).get('availableModels', []))} "
            f"modes={[m.get('id') for m in r.get('modes', {}).get('availableModes', [])]} "
            f"configOptions={[c.get('id') for c in r.get('configOptions', [])]}",
        )
        session_id = new_reply.get("result", {}).get("sessionId")
        config_options = new_reply.get("result", {}).get("configOptions", [])
        if not session_id:
            print("session/new không trả sessionId, bỏ qua các phương thức theo phiên.")
        else:
            report(
                results,
                "session/list",
                client.request("session/list", {}, t),
                lambda r: f"{len(r.get('sessions', []))} phiên" + (
                    f", mới nhất: {r['sessions'][0].get('title')!r}" if r.get("sessions") else ""
                ),
            )
            report(
                results,
                "session/load",
                client.request(
                    "session/load",
                    {"sessionId": session_id, "cwd": args.cwd, "mcpServers": []},
                    t,
                ),
                lambda r: f"sessionId={(r or {}).get('sessionId')} (phát lại lịch sử qua session/update)",
            )
            modes = [m.get("id") for m in new_reply.get("result", {}).get("modes", {}).get("availableModes", [])]
            if modes:
                report(
                    results,
                    "session/set_mode",
                    client.request("session/set_mode", {"sessionId": session_id, "modeId": modes[-1]}, t),
                )
            models = [m.get("modelId") for m in new_reply.get("result", {}).get("models", {}).get("availableModels", [])]
            if models:
                report(
                    results,
                    "session/set_model",
                    client.request("session/set_model", {"sessionId": session_id, "modelId": models[-1]}, t),
                )
            # Đổi từng config option; sau mỗi lần đổi, lấy lại danh sách từ phản hồi vì đổi model
            # có thể đổi các mức (thought_level) được phép dùng.
            pending = list(config_options)
            tried: set[str] = set()
            while pending:
                option = pending.pop(0)
                if option.get("id") in tried:
                    continue
                tried.add(option.get("id"))
                values = [o.get("value") for o in option.get("options", []) if o.get("value")]
                if not values:
                    continue
                reply = report(
                    results,
                    f"session/set_config_option:{option.get('id')}",
                    client.request(
                        "session/set_config_option",
                        {"sessionId": session_id, "configId": option["id"], "value": values[0]},
                        t,
                    ),
                )
                refreshed = (reply or {}).get("result", {}).get("configOptions")
                if refreshed:
                    pending = [c for c in refreshed if c.get("id") not in tried] + pending
            if args.with_prompt:
                report(
                    results,
                    "session/prompt",
                    client.request(
                        "session/prompt",
                        {"sessionId": session_id, "prompt": [{"type": "text", "text": args.with_prompt}]},
                        max(t, 180),
                    ),
                    lambda r: f"stopReason={(r or {}).get('stopReason')} usage={summarize((r or {}).get('usage'), 100)}",
                )
            # session/cancel là notification (không có id): gửi và xác nhận không lỗi tiến trình
            client.notify("session/cancel", {"sessionId": session_id})
            alive = client.proc.poll() is None
            print(f"{'session/cancel':26s} {'GỬI (notification)':14s} tiến trình còn sống={alive}")
            results.append({"method": "session/cancel", "status": "GỬI", "detail": f"alive={alive}"})
            report(
                results,
                "session/close",
                client.request("session/close", {"sessionId": session_id}, t),
            )

        # Phương thức không tồn tại và tên đoán: kỳ vọng -32601 Method not found
        for name in ("account/info", "quota/get", "nonexistent/method"):
            report(results, name, client.request(name, {}, t))

        print("-" * 100)
        if client.notifications:
            kinds = sorted({n["method"] for n in client.notifications})
            print("notification đã nhận:", ", ".join(kinds))
        print("LƯU Ý: `logout` không được gọi (kiểm tra tay).")
    finally:
        client.close()

    out = os.environ.get("ACP_PROBE_JSON")
    if out:
        with open(out, "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
        print(f"đã ghi kết quả: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
