#!/usr/bin/env python3
"""Tổng hợp lượt tải từ access log của nginx (chỉ các request tải file từ host công khai).

Đọc log theo offset (không đọc lại toàn bộ), ghi kết quả JSON nguyên tử vào STATS_FILE.
Chỉ dùng thư viện chuẩn để image nhỏ và không có phụ thuộc.

Một "lượt tải" = một request GET trả 200 cho một file trong /assets/downloads/.
HEAD, 206 (tải tiếp), 404 và các request khác không được tính.
"""
import datetime as dt
import json
import os
import re
import tempfile
import time
import traceback

LOG_FILE = os.environ.get("LOG_FILE", "/logs/access.log")
STATE_FILE = os.environ.get("STATE_FILE", "/logs/stats-state.json")
STATS_FILE = os.environ.get("STATS_FILE", "/stats/downloads.json")
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "300"))

PREFIX = "/assets/downloads/"
PLATFORM_BY_EXT = {".deb": "linux", ".apk": "android", ".ipa": "ios", ".zip": "macos"}
KEEP_DAYS = 90

# Khớp format dl_log trong nginx.conf:
# $time_iso8601 $host $request_method $uri $status $body_bytes_sent
LINE = re.compile(
    r"^(?P<time>\S+) (?P<host>\S+) (?P<method>\S+) (?P<uri>\S+) (?P<status>\d{3}) (?P<bytes>\d+)$"
)


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def save_atomic(path, data):
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def consume_new_lines(state):
    """Đọc phần log mới kể từ offset đã lưu, cập nhật state tại chỗ."""
    try:
        size = os.path.getsize(LOG_FILE)
    except FileNotFoundError:
        return state
    offset = state.get("offset", 0)
    if size < offset:  # log bị cắt hoặc xoay vòng: đọc lại từ đầu
        offset = 0
    with open(LOG_FILE, "rb") as f:
        f.seek(offset)
        data = f.read()
    end = data.rfind(b"\n")
    if end == -1:  # chưa có dòng hoàn chỉnh nào
        return state
    state["offset"] = offset + end + 1

    files = state.setdefault("files", {})
    for raw in data[: end + 1].decode("utf-8", "replace").splitlines():
        m = LINE.match(raw)
        if not m:
            continue
        if m["method"] != "GET" or m["status"] != "200":
            continue
        uri = m["uri"].split("?", 1)[0]
        if not uri.startswith(PREFIX):
            continue
        name = uri[len(PREFIX):]
        if not name or "/" in name:
            continue
        day = m["time"][:10]  # YYYY-MM-DD, theo giờ của máy chủ
        rec = files.setdefault(name, {"total": 0, "daily": {}})
        rec["total"] += 1
        rec["daily"][day] = rec["daily"].get(day, 0) + 1

    cutoff = (dt.date.today() - dt.timedelta(days=KEEP_DAYS)).isoformat()
    for rec in files.values():
        rec["daily"] = {d: n for d, n in rec["daily"].items() if d >= cutoff}
    return state


def build_output(state):
    today = dt.date.today()
    last30_start = (today - dt.timedelta(days=29)).isoformat()
    files_out = {}
    platforms = {}
    total = 0
    for name, rec in sorted(state.get("files", {}).items()):
        ext = os.path.splitext(name)[1].lower()
        platform = PLATFORM_BY_EXT.get(ext, "other")
        last30 = sum(n for d, n in rec["daily"].items() if d >= last30_start)
        files_out[name] = {"platform": platform, "total": rec["total"], "last30": last30}
        platforms[platform] = platforms.get(platform, 0) + rec["total"]
        total += rec["total"]
    return {
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "total": total,
        "platforms": platforms,
        "files": files_out,
    }


def run_once():
    state = load_json(STATE_FILE, {})
    state = consume_new_lines(state)
    save_atomic(STATE_FILE, state)
    save_atomic(STATS_FILE, build_output(state))


def main():
    print(f"count_downloads: log={LOG_FILE} out={STATS_FILE} every {INTERVAL}s", flush=True)
    while True:
        try:
            run_once()
        except Exception:  # không để sidecar chết vì một lỗi tạm thời
            traceback.print_exc()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
