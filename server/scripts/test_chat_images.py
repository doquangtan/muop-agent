#!/usr/bin/env python3
"""Kiểm thử ảnh đính kèm qua REST API của muop-agent-server (Claude CLI và agy).

Yêu cầu server đang chạy (mặc định http://127.0.0.1:8787). Mỗi lượt là một lượt chat thật,
tốn quota model nhỏ. Các conversation được tạo ra sẽ xuất hiện trong danh sách session.

    python3 server/scripts/test_chat_images.py                 # cả Claude và agy
    python3 server/scripts/test_chat_images.py --only claude
    python3 server/scripts/test_chat_images.py --only agy --agy-model agy:gemini-4-hydrogen-low

Ảnh test được sinh trong thư mục tạm (cần Pillow). Thoát với mã 1 nếu có kiểm tra thất bại.
"""

import argparse
import base64
import io
import json
import sys
import time
import urllib.error
import urllib.request
import os

from PIL import Image

def make_image(size, color, fmt):
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, format=fmt)
    return buf.getvalue()


def chat_image(name, raw):
    mime = {"PNG": "image/png", "JPEG": "image/jpeg"}[Image.open(io.BytesIO(raw)).format]
    return {
        "name": name,
        "mimeType": mime,
        "dataBase64": base64.b64encode(raw).decode("ascii"),
    }


class Api:
    def __init__(self, base):
        self.base = base.rstrip("/")

    def _request(self, method, path, payload=None):
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = urllib.request.Request(
            self.base + path,
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as e:
            body = e.read()
            try:
                return e.code, json.loads(body)
            except json.JSONDecodeError:
                return e.code, {"raw": body.decode("utf-8", "replace")}

    def send(self, prompt, model, conversation_id="", images=None):
        return self._request(
            "POST",
            "/api/chat/send",
            {
                "prompt": prompt,
                "projectPath": PROJECT_PATH,
                "conversationId": conversation_id,
                "agentName": "",
                "model": model,
                "images": images or [],
            },
        )

    def get_image(self, url):
        """Tải ảnh qua endpoint đính kèm, trả về (mã HTTP, Content-Type, bytes)."""
        req = urllib.request.Request(self.base + url, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.status, resp.headers.get("Content-Type", ""), resp.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers.get("Content-Type", ""), e.read()

    def session(self, cid):
        _, body = self._request("GET", "/api/session?id=" + cid)
        return body

    def streams(self):
        _, body = self._request("GET", "/api/streams")
        return body.get("activeStreams", {})

    def wait_done(self, cid, timeout=300):
        """Chờ lượt chat xong: không còn stream đang chạy và trạng thái session là kết thúc."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(3)
            if cid in self.streams():
                continue
            session = self.session(cid)
            status = session.get("status")
            if status not in (None, "", "running") and session.get("steps"):
                return session
        raise TimeoutError(f"Lượt {cid} chưa xong sau {timeout}s")


def check_image_urls(api, user_step, expected_sizes, checks):
    """Kiểm tra bước người dùng có imageUrls và mỗi URL tải về được một ảnh đúng kích thước."""
    urls = user_step.get("imageUrls", [])
    if not checks.check(
        len(urls) == len(expected_sizes),
        f"imageUrls có {len(expected_sizes)} phần tử",
        str(urls),
    ):
        return
    for i, (url, size) in enumerate(zip(urls, expected_sizes)):
        status, ctype, data = api.get_image(url)
        checks.check(status == 200 and ctype.startswith("image/"), f"tải ảnh {i + 1} qua endpoint", f"HTTP {status} {ctype}")
        try:
            got = Image.open(io.BytesIO(data)).size
        except Exception as e:  # noqa: BLE001 - báo lỗi giải mã như kiểm tra thất bại
            got = f"không giải mã được: {e}"
        checks.check(got == size, f"ảnh {i + 1} có kích thước {size}", str(got))


def answer_after_last_user(session):
    """Ghép nội dung các bước model trả lời sau bước người dùng cuối cùng."""
    steps = session.get("steps", [])
    last_user = max(
        (i for i, s in enumerate(steps) if s.get("type") == "USER_INPUT"), default=-1
    )
    return "\n".join(
        s.get("content", "") for s in steps[last_user + 1 :] if s.get("content")
    )


def last_user_step(session):
    users = [s for s in session.get("steps", []) if s.get("type") == "USER_INPUT"]
    return users[-1] if users else {}


class Checks:
    def __init__(self):
        self.failed = 0

    def check(self, ok, label, detail=""):
        mark = "PASS" if ok else "FAIL"
        if not ok:
            self.failed += 1
        suffix = f" — {detail}" if detail and not ok else ""
        print(f"  [{mark}] {label}{suffix}")
        return ok


def run_provider(api, label, model, checks):
    print(f"\n=== {label} ({model}) ===")
    red = make_image((64, 64), (220, 30, 30), "PNG")
    blue_big = make_image((3000, 1500), (30, 60, 220), "PNG")

    # 1. Một ảnh + câu hỏi, kiểm tra model thật sự thấy ảnh
    print("1. Một ảnh đỏ + câu hỏi")
    status, res = api.send(
        "Màu chính của ảnh là gì? Chỉ trả lời một từ tiếng Anh viết thường.",
        model,
        images=[chat_image("red.png", red)],
    )
    if not checks.check(status == 200 and res.get("ok"), "POST /api/chat/send thành công", str(res)):
        return
    cid = res["conversationId"]
    print(f"  conversation: {cid} (source={res.get('source')})")
    session = api.wait_done(cid)
    answer = answer_after_last_user(session)
    checks.check("red" in answer.lower(), "model trả lời đúng màu (red)", repr(answer[:200]))
    checks.check(
        last_user_step(session).get("imageCount") == 1,
        "bước người dùng ghi imageCount = 1",
        str(last_user_step(session).get("imageCount")),
    )
    check_image_urls(api, last_user_step(session), [(64, 64)], checks)

    # 2. Lượt tiếp theo chỉ có chữ, phải nhớ ảnh trước (tiếp tục đúng session)
    print("2. Hỏi tiếp không kèm ảnh (kiểm tra resume)")
    status, res = api.send(
        "Màu của ảnh bạn vừa xem là gì? Chỉ trả lời một từ tiếng Anh viết thường.",
        model,
        conversation_id=cid,
    )
    checks.check(status == 200 and res.get("ok"), "lượt tiếp theo gửi được", str(res))
    session = api.wait_done(cid)
    answer = answer_after_last_user(session)
    checks.check("red" in answer.lower(), "lượt sau vẫn nhớ ảnh (red)", repr(answer[:200]))

    # 3. Hai ảnh, một ảnh lớn cần thu nhỏ
    print("3. Hai ảnh (một ảnh 3000x1500 cần thu nhỏ)")
    status, res = api.send(
        "Ảnh thứ nhất màu gì, ảnh thứ hai màu gì? Trả lời ngắn bằng tiếng Anh, dạng: first <màu>, second <màu>.",
        model,
        conversation_id=cid,
        images=[chat_image("red.png", red), chat_image("blue.png", blue_big)],
    )
    checks.check(status == 200 and res.get("ok"), "gửi hai ảnh thành công", str(res))
    session = api.wait_done(cid)
    answer = answer_after_last_user(session).lower()
    checks.check(
        "red" in answer and "blue" in answer,
        "model mô tả đúng cả hai ảnh (red, blue)",
        repr(answer[:200]),
    )
    checks.check(
        last_user_step(session).get("imageCount") == 2,
        "bước người dùng ghi imageCount = 2",
        str(last_user_step(session).get("imageCount")),
    )
    # Ảnh 3000x1500 phải được thu về cạnh dài 1568 khi tải lại
    check_image_urls(api, last_user_step(session), [(64, 64), (1568, 784)], checks)

    # 4. Chỉ có ảnh, không có chữ: server dùng câu mặc định
    print("4. Chỉ gửi ảnh, không có chữ")
    status, res = api.send("", model, images=[chat_image("red.png", red)])
    checks.check(status == 200 and res.get("ok"), "gửi ảnh không chữ thành công", str(res))
    if res.get("ok"):
        session = api.wait_done(res["conversationId"])
        user = last_user_step(session)
        checks.check(bool(user.get("content")), "có nội dung mặc định trong lịch sử", repr(user.get("content")))
        checks.check(user.get("imageCount") == 1, "imageCount = 1 cho lượt chỉ có ảnh", str(user.get("imageCount")))
        checks.check(bool(answer_after_last_user(session).strip()), "model có trả lời")

    # 5. Kiểm tra đầu vào sai (không tốn quota: server từ chối trước khi gọi CLI)
    print("5. Đầu vào không hợp lệ (bị từ chối trước khi chạy CLI)")
    status, res = api.send("x", model, images=[chat_image(f"{i}.png", red) for i in range(7)])
    checks.check(status == 400 and "Tối đa" in res.get("error", ""), "7 ảnh bị từ chối (400)", str(res))
    status, res = api.send(
        "x", model, images=[{"name": "bad.png", "mimeType": "image/png", "dataBase64": "!!!"}]
    )
    checks.check(status == 400 and "base64" in res.get("error", ""), "base64 hỏng bị từ chối (400)", str(res))
    text_as_image = base64.b64encode(b"day la text, khong phai anh").decode("ascii")
    status, res = api.send(
        "x", model, images=[{"name": "fake.png", "mimeType": "image/png", "dataBase64": text_as_image}]
    )
    checks.check(status == 400 and "không phải file ảnh" in res.get("error", ""), "file không phải ảnh bị từ chối (400)", str(res))
    status, res = api.send("   ", model)
    checks.check(status == 400 and res.get("error") == "Nội dung tin nhắn trống", "tin trống, không ảnh bị từ chối (400)", str(res))


# Thư mục project gửi kèm mỗi lượt: MUOP_TEST_PROJECT, nếu không có thì workspace đã cấu hình trên server
PROJECT_PATH = os.environ.get("MUOP_TEST_PROJECT", "")


def workspace_from_server(base):
    with urllib.request.urlopen(base.rstrip("/") + "/api/setup/status", timeout=10) as r:
        return json.loads(r.read().decode()).get("workspaceRoot", "")


def main():
    global PROJECT_PATH
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default="http://127.0.0.1:8787")
    parser.add_argument("--claude-model", default="claude-cli:claude-haiku-5-5")
    parser.add_argument("--agy-model", default="agy:gemini-4-hydrogen-low")
    parser.add_argument("--only", choices=["claude", "agy"], help="chỉ chạy một provider")
    args = parser.parse_args()

    if not PROJECT_PATH:
        PROJECT_PATH = workspace_from_server(args.base)
    if not PROJECT_PATH:
        print("Chưa có thư mục project: đặt MUOP_TEST_PROJECT hoặc chọn workspace trong Khởi tạo")
        return 2

    api = Api(args.base)
    checks = Checks()
    if args.only in (None, "claude"):
        run_provider(api, "Claude CLI", args.claude_model, checks)
    if args.only in (None, "agy"):
        run_provider(api, "agy", args.agy_model, checks)

    print(f"\nKết quả: {'TẤT CẢ ĐẠT' if checks.failed == 0 else str(checks.failed) + ' kiểm tra thất bại'}")
    return 1 if checks.failed else 0


if __name__ == "__main__":
    sys.exit(main())
