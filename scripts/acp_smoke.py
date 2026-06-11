#!/usr/bin/env python3
"""Smoke test: drive refman-agent over ACP like the app would."""
import json
import subprocess
import sys
import threading

proc = subprocess.Popen(
    [".build/debug/refman-agent"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
)

pending = {}
done = threading.Event()
chunks = []


def send(obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()


def reader():
    for line in proc.stdout:
        msg = json.loads(line)
        if msg.get("method") == "session/update":
            content = msg["params"]["update"].get("content", {})
            text = content.get("text", "")
            chunks.append(text)
            sys.stdout.write(text)
            sys.stdout.flush()
        elif msg.get("method") == "refman/toolCall":
            name = msg["params"]["name"]
            print(f"\n<<tool call: {name} {msg['params'].get('arguments')}>>")
            send({
                "jsonrpc": "2.0", "id": msg["id"],
                "result": {"result": "Title: Attention Is All You Need. "
                           "Authors: Vaswani et al. Year: 2017. "
                           "Abstract: Introduces the Transformer architecture."},
            })
        elif "id" in msg:
            pending[msg["id"]] = msg
            if msg["id"] == 3:
                done.set()


threading.Thread(target=reader, daemon=True).start()

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"protocolVersion": 1}})
send({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": "/tmp"}})

import time
time.sleep(2)
session = pending[2]["result"]["sessionId"]
prompt = sys.argv[1] if len(sys.argv) > 1 else "What paper is currently open? Use your tools, then answer in one sentence."
send({"jsonrpc": "2.0", "id": 3, "method": "session/prompt",
      "params": {"sessionId": session,
                 "prompt": [{"type": "text", "text": prompt}]}})

if not done.wait(timeout=180):
    print("\nTIMED OUT")
    proc.kill()
    sys.exit(1)

print(f"\n--- stopReason: {pending[3]['result']['stopReason']} ---")
proc.kill()
