"""A tiny MCP server over Streamable HTTP, for KuriMCP's tests. Standard library only.

Answers every request with plain JSON (no SSE), refuses the optional GET
stream with 405, and requires `Authorization: Bearer test`.
Prints the port it listens on as its first line of output.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SESSION = "fixture-session"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def authorized(self):
        if self.headers.get("Authorization") != "Bearer test":
            self.send_response(401)
            self.end_headers()
            return False
        return True

    def do_GET(self):
        self.send_response(405)
        self.end_headers()

    def do_DELETE(self):
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        if not self.authorized():
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        message = json.loads(body)
        if "id" not in message:
            self.send_response(202)
            self.end_headers()
            return
        method = message.get("method")
        reply = {"jsonrpc": "2.0", "id": message["id"]}
        if method == "initialize":
            reply["result"] = {
                "protocolVersion": message["params"]["protocolVersion"],
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "http-fixture", "version": "1.0"},
            }
        elif method == "tools/list":
            reply["result"] = {"tools": [{
                "name": "shout", "description": "Upper-case the text.",
                "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}},
                "annotations": {"readOnlyHint": True},
            }]}
        elif method == "tools/call":
            text = (message["params"].get("arguments") or {}).get("text", "")
            reply["result"] = {"content": [{"type": "text", "text": text.upper()}]}
        else:
            reply["error"] = {"code": -32601, "message": "method not found"}
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Mcp-Session-Id", SESSION)
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
