#!/usr/bin/env python3
import sys
import json
import urllib.request
import asyncio

async def main():
    target_conv_id = sys.argv[1].strip() if len(sys.argv) > 1 else ""
    try:
        req = urllib.request.urlopen("http://127.0.0.1:41819/json", timeout=1.5)
        targets = json.loads(req.read().decode())
    except Exception:
        return

    import websockets

    for t in targets:
        url = t.get("url", "")
        ws_url = t.get("webSocketDebuggerUrl", "")
        if not ws_url:
            continue

        if not target_conv_id or target_conv_id in url or target_conv_id == "any":
            try:
                async with websockets.connect(ws_url, open_timeout=2) as ws:
                    if "tab=review" in url and target_conv_id:
                        expr = f"window.history.replaceState({{}}, '', '/c/{target_conv_id}');"
                        await ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": expr}}))
                        try:
                            await ws.recv()
                        except Exception:
                            pass

                    # Luôn luôn Page.reload để Electron Antigravity IDE đọc lại transcript.jsonl từ đĩa
                    await ws.send(json.dumps({"id": 2, "method": "Page.reload"}))
                    try:
                        await ws.recv()
                    except Exception:
                        pass
            except Exception:
                pass

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception:
        pass
