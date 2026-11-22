"""A tiny MCP server over stdio, for KuriMCP's tests. Standard library only.

Tools:
  echo    read-only; returns its `text` argument
  add     returns a + b
  unlock  adds the `secret` tool and sends notifications/tools/list_changed
  fail    returns isError: true
  crash   exits with status 3
  slow    sleeps for `seconds`
"""
import json
import sys
import time

unlocked = False


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def tools():
    listed = [
        {"name": "echo", "description": "Echo the text back.",
         "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
         "annotations": {"readOnlyHint": True}},
        {"name": "add", "description": "Add two numbers.",
         "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}}},
        {"name": "unlock", "description": "Reveal another tool.", "inputSchema": {"type": "object"}},
        {"name": "fail", "description": "Always fails.", "inputSchema": {"type": "object"}},
        {"name": "crash", "description": "Exit the server.", "inputSchema": {"type": "object"}},
        {"name": "slow", "description": "Sleep.", "inputSchema": {"type": "object", "properties": {"seconds": {"type": "number"}}}},
    ]
    if unlocked:
        listed.append({"name": "secret", "description": "Only after unlock.", "inputSchema": {"type": "object"}})
    return listed


def text(value):
    return {"content": [{"type": "text", "text": value}]}


def call(name, args):
    global unlocked
    if name == "echo":
        return text(args.get("text", ""))
    if name == "add":
        return text(str(args.get("a", 0) + args.get("b", 0)))
    if name == "unlock":
        unlocked = True
        send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        return text("unlocked")
    if name == "fail":
        return {"content": [{"type": "text", "text": "it broke"}], "isError": True}
    if name == "crash":
        sys.exit(3)
    if name == "slow":
        time.sleep(args.get("seconds", 1))
        return text("done")
    if name == "secret":
        return text("42")
    return None


sys.stderr.write("fixture started\n")
sys.stderr.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    method = message.get("method")
    if "id" not in message:
        continue  # notifications (initialized, cancelled) need no answer
    reply = {"jsonrpc": "2.0", "id": message["id"]}
    if method == "initialize":
        reply["result"] = {
            "protocolVersion": message["params"]["protocolVersion"],
            "capabilities": {"tools": {"listChanged": True}},
            "serverInfo": {"name": "fixture", "version": "1.0"},
        }
    elif method == "tools/list":
        reply["result"] = {"tools": tools()}
    elif method == "tools/call":
        result = call(message["params"]["name"], message["params"].get("arguments") or {})
        if result is None:
            reply["error"] = {"code": -32602, "message": "unknown tool"}
        else:
            reply["result"] = result
    elif method == "ping":
        reply["result"] = {}
    else:
        reply["error"] = {"code": -32601, "message": "method not found"}
    send(reply)
