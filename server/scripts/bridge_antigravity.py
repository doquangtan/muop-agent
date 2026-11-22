#!/usr/bin/env python3
import sys
import os
import time
import json
import asyncio
import urllib.request
import subprocess
import shutil

CDP_JSON_URL = "http://127.0.0.1:41819/json"

def emit_event(event_data):
    try:
        sys.stdout.write(json.dumps(event_data, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    except Exception:
        pass

def get_cdp_targets():
    try:
        req = urllib.request.urlopen(CDP_JSON_URL, timeout=1.5)
        return json.loads(req.read().decode())
    except Exception:
        return []

async def submit_via_cdp(conv_id, prompt, model, cwd):
    targets = get_cdp_targets()
    page_target = None
    for t in targets:
        if t.get("type") == "page" and t.get("webSocketDebuggerUrl") and t.get("url", "").startswith("https://127.0.0.1"):
            page_target = t
            break

    if not page_target:
        for t in targets:
            if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                page_target = t
                break

    if not page_target:
        return False

    ws_url = page_target["webSocketDebuggerUrl"]
    import websockets

    async with websockets.connect(ws_url, open_timeout=3, ping_interval=None) as ws:
        msg_id = 0

        async def send_cmd(method, params=None):
            nonlocal msg_id
            msg_id += 1
            payload = {"id": msg_id, "method": method}
            if params:
                payload["params"] = params
            await ws.send(json.dumps(payload))
            while True:
                resp_raw = await ws.recv()
                data = json.loads(resp_raw)
                if data.get("id") == msg_id:
                    return data

        # 1. Determine conversation ID and navigation
        eval_res = await send_cmd("Runtime.evaluate", {
            "expression": "(() => ({ path: window.location.pathname, title: document.title }))()",
            "returnByValue": True
        })
        current_path = eval_res.get("result", {}).get("result", {}).get("value", {}).get("path", "")

        actual_conv_id = conv_id.strip() if conv_id else ""
        if not actual_conv_id or actual_conv_id == "new":
            if current_path.startswith("/c/"):
                actual_conv_id = current_path.replace("/c/", "").split("/")[0]

        if conv_id and conv_id != "new" and not current_path.startswith(f"/c/{conv_id}"):
            await send_cmd("Runtime.evaluate", {
                "expression": f"window.location.href = '/c/{conv_id}'"
            })
            await asyncio.sleep(1.5)
            actual_conv_id = conv_id

        # Immediately inform caller of resolved conversation_id
        emit_event({"event": "init", "conversation_id": actual_conv_id})

        # 2. Focus editor
        await send_cmd("Runtime.evaluate", {
            "expression": """(() => {
                const ed = document.querySelector('[contenteditable="true"]');
                if (ed) {
                    ed.focus();
                    return true;
                }
                return false;
            })()""",
            "returnByValue": True
        })

        # 3. Clear any existing content
        await send_cmd("Input.dispatchKeyEvent", {
            "type": "keyDown", "modifiers": 2, "windowsVirtualKeyCode": 65, "code": "KeyA", "key": "a"
        })
        await send_cmd("Input.dispatchKeyEvent", {
            "type": "keyUp", "modifiers": 2, "windowsVirtualKeyCode": 65, "code": "KeyA", "key": "a"
        })
        await send_cmd("Input.dispatchKeyEvent", {
            "type": "keyDown", "windowsVirtualKeyCode": 8, "code": "Backspace", "key": "Backspace"
        })
        await send_cmd("Input.dispatchKeyEvent", {
            "type": "keyUp", "windowsVirtualKeyCode": 8, "code": "Backspace", "key": "Backspace"
        })

        # 4. Insert user prompt text via native CDP Input
        await send_cmd("Input.insertText", {"text": prompt})
        await asyncio.sleep(0.15)

        # Track transcript log file
        transcript_path = os.path.expanduser(f"~/.gemini/antigravity/brain/{actual_conv_id}/.system_generated/logs/transcript.jsonl")
        start_size = os.path.getsize(transcript_path) if os.path.exists(transcript_path) else 0

        # 5. Click Send button or dispatch Enter
        click_res = await send_cmd("Runtime.evaluate", {
            "expression": """(() => {
                const btn = document.querySelector('[data-testid="send-button"]');
                if (btn && !btn.disabled) {
                    btn.click();
                    return { ok: true, method: 'click' };
                }
                return { ok: false };
            })()""",
            "returnByValue": True
        })
        clicked = click_res.get("result", {}).get("result", {}).get("value", {}).get("ok", False)
        if not clicked:
            await send_cmd("Input.dispatchKeyEvent", {
                "type": "keyDown", "windowsVirtualKeyCode": 13, "code": "Enter", "key": "Enter"
            })
            await send_cmd("Input.dispatchKeyEvent", {
                "type": "keyUp", "windowsVirtualKeyCode": 13, "code": "Enter", "key": "Enter"
            })

        # 6. Stream and monitor loop
        last_offset = start_size
        read_buffer = ""
        accumulated_text = ""
        seen_turn_active = False
        idle_ticks = 0

        for _ in range(360):  # max 180 seconds
            await asyncio.sleep(0.5)

            # Check isRunning via React fiber or Cancel button
            status_res = await send_cmd("Runtime.evaluate", {
                "expression": """(() => {
                    const cancelBtn = document.querySelector('[aria-label="Cancel (Ctrl+D)"]');
                    const editor = document.querySelector('[contenteditable="true"]');
                    let isRunning = !!cancelBtn;
                    if (editor) {
                        const fiberKey = Object.keys(editor).find(k => k.startsWith('__reactFiber'));
                        let fiber = fiberKey ? editor[fiberKey] : null;
                        while (fiber) {
                            if (fiber.memoizedProps && typeof fiber.memoizedProps.isRunning === 'boolean') {
                                isRunning = fiber.memoizedProps.isRunning;
                                break;
                            }
                            fiber = fiber.return;
                        }
                    }
                    return { isRunning };
                })()""",
                "returnByValue": True
            })
            is_running = status_res.get("result", {}).get("result", {}).get("value", {}).get("isRunning", False)

            if is_running:
                seen_turn_active = True
                idle_ticks = 0

            # Tail transcript.jsonl
            if os.path.exists(transcript_path):
                try:
                    curr_size = os.path.getsize(transcript_path)
                    if curr_size > last_offset:
                        with open(transcript_path, "r", encoding="utf-8", errors="ignore") as f:
                            f.seek(last_offset)
                            chunk = f.read()
                            last_offset = f.tell()

                        read_buffer += chunk
                        while "\n" in read_buffer:
                            line, read_buffer = read_buffer.split("\n", 1)
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                step = json.loads(line)
                                step_type = step.get("type", "")
                                src = step.get("source", "")

                                if step_type == "PLANNER_RESPONSE" and src == "MODEL":
                                    content = step.get("content")
                                    if content and isinstance(content, str):
                                        if len(content) > len(accumulated_text):
                                            delta = content[len(accumulated_text):]
                                            accumulated_text = content
                                            emit_event({
                                                "event": "step_update",
                                                "step_update": {
                                                    "conversation_id": actual_conv_id,
                                                    "step_type": "agent_response",
                                                    "text_delta": delta
                                                }
                                            })
                                    tool_calls = step.get("tool_calls", [])
                                    for tc in tool_calls:
                                        tname = tc.get("name", "")
                                        args = tc.get("args", {})
                                        summary = args.get("toolSummary", tname)
                                        emit_event({
                                            "event": "step_update",
                                            "step_update": {
                                                "conversation_id": actual_conv_id,
                                                "step_type": "tool_call",
                                                "text_delta": f"\n🛠️ *{summary}*...\n"
                                            }
                                        })
                            except Exception:
                                pass
                except Exception:
                    pass

            if seen_turn_active and not is_running:
                idle_ticks += 1
                if idle_ticks >= 2:
                    break
            elif not seen_turn_active:
                idle_ticks += 1
                if idle_ticks > 16:  # 8 seconds without activating
                    break

        # Read any remaining buffered lines after turn finishes
        if os.path.exists(transcript_path):
            try:
                curr_size = os.path.getsize(transcript_path)
                if curr_size > last_offset:
                    with open(transcript_path, "r", encoding="utf-8", errors="ignore") as f:
                        f.seek(last_offset)
                        chunk = f.read()
                    for line in chunk.splitlines():
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            step = json.loads(line)
                            if step.get("type") == "PLANNER_RESPONSE" and step.get("source") == "MODEL":
                                c = step.get("content")
                                if c and isinstance(c, str):
                                    accumulated_text = c
                        except Exception:
                            pass
            except Exception:
                pass

        emit_event({
            "event": "result",
            "result": {
                "response": accumulated_text
            }
        })
        return True

def fallback_agy_cli(conv_id, prompt, model, cwd):
    agy_bin = shutil.which("agy") or "agy"  # dò trong PATH, không đoán đường dẫn cố định
    args = [
        agy_bin,
        "--app_data_dir=antigravity",
        "--dangerously-skip-permissions",
        "--output-format=stream-json",
    ]
    if conv_id and conv_id != "new":
        args.extend(["--conversation", conv_id])
    if model and model != "default":
        args.extend(["--model", model])
    else:
        args.extend(["--model", "gemini-3.8-flash-high"])
    args.extend(["-p", prompt])

    proc = subprocess.Popen(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
    proc.wait()

async def stop_turn_cdp():
    targets = get_cdp_targets()
    for t in targets:
        if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
            try:
                import websockets
                async with websockets.connect(t["webSocketDebuggerUrl"], open_timeout=2) as ws:
                    await ws.send(json.dumps({
                        "id": 1,
                        "method": "Runtime.evaluate",
                        "params": {
                            "expression": """(() => {
                                const cancelBtn = document.querySelector('[aria-label="Cancel (Ctrl+D)"]');
                                if (cancelBtn) { cancelBtn.click(); return true; }
                                return false;
                            })()"""
                        }
                    }))
                    await ws.recv()
                    return True
            except Exception:
                pass
    return False

def main():
    if len(sys.argv) < 2:
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "stop":
        asyncio.run(stop_turn_cdp())
        sys.exit(0)

    if cmd == "send":
        conv_id = sys.argv[2] if len(sys.argv) > 2 else ""
        prompt = sys.argv[3] if len(sys.argv) > 3 else ""
        model = sys.argv[4] if len(sys.argv) > 4 else "gemini-3.8-flash-high"
        cwd = sys.argv[5] if len(sys.argv) > 5 else os.getcwd()

        success = False
        try:
            success = asyncio.run(submit_via_cdp(conv_id, prompt, model, cwd))
        except Exception as e:
            sys.stderr.write(f"CDP submission error: {e}\n")
            success = False

        if not success:
            sys.stderr.write("CDP not available or failed; falling back to agy CLI...\n")
            fallback_agy_cli(conv_id, prompt, model, cwd)

if __name__ == "__main__":
    main()
