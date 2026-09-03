#!/usr/bin/env python3
"""Mock ESP32 WebSocket/HTTP server and test client for ws-tests.

Modes:
  python ws_test_stub.py mock [--http-port 8080] [--ws-port 8081]
      Starts a local HTTP + WebSocket server that mimics the ESP32 firmware.

  python ws_test_stub.py test --host 192.168.4.1
      Tests a real ESP32 (or the mock) over HTTP and WebSocket.

Defaults for `test` assume the real board:
  HTTP port 80, WebSocket port 81, password afsk12345.
"""

import argparse
import asyncio
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

import websockets

DEFAULT_WS_PORT = 81
DEFAULT_HTTP_PORT = 80
MOCK_WS_PORT = 8081
MOCK_HTTP_PORT = 8080
WS_MAX_FRAME_LEN = 1024


# ---------------------------------------------------------------------------
# Mock server
# ---------------------------------------------------------------------------

class MockEsp32State:
    def __init__(self):
        self.clients = {}  # websocket -> name
        self.lock = asyncio.Lock()


STATE = MockEsp32State()


async def mock_ws_handler(websocket):
    """Mimics the ESP32 WebSocket endpoint on port 81."""
    async with STATE.lock:
        STATE.clients[websocket] = ""

    # Send a system greeting, like the real board does on connect.
    await websocket.send("System:Mock ready")

    try:
        async for message in websocket:
            if len(message.encode("utf-8")) > WS_MAX_FRAME_LEN:
                await websocket.send("System:Frame too long")
                continue

            if message.startswith("setName:"):
                name = message[len("setName:"):]
                async with STATE.lock:
                    STATE.clients[websocket] = name
                print(f"[WS] Client setName: {name}")
                continue

            # Accept either legacy msg:<name>:<text> or new msg:<name>:<id>:<text>
            m = re.match(r"msg:([^:]+):(.*)", message, re.DOTALL)
            if m:
                name, tail = m.group(1), m.group(2)
                # If tail contains another colon, the format is msg:<name>:<id>:<text>
                colon = tail.find(':')
                if colon >= 0:
                    broadcast = f"{name}:{tail}"
                else:
                    broadcast = f"{name}:{tail}"
                async with STATE.lock:
                    STATE.clients[websocket] = name
                print(f"[WS] Received msg from {name}: {tail[:80]!r}")
                # Echo back in the same format the real board uses: <name>:<tail>
                await websocket.send(broadcast)
                continue

            print(f"[WS] Unknown frame: {message[:80]!r}")
    finally:
        async with STATE.lock:
            STATE.clients.pop(websocket, None)


class MockHttpHandler(BaseHTTPRequestHandler):
    """Mimics the ESP32 HTTP endpoints on port 80."""

    def log_message(self, fmt, *args):
        print(f"[HTTP] {fmt % args}")

    def _send(self, code, body, content_type="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/ping":
            self._send(200, b"pong")
        elif self.path == "/info":
            body = json.dumps({"ssid": "AFSK-TRX-MOCK", "ip": "192.168.4.1"}).encode()
            self._send(200, body, "application/json")
        else:
            self._send(404, b"Not found")

    def do_POST(self):
        if self.path == "/send":
            length = int(self.headers.get("Content-Length", 0))
            data = self.rfile.read(length).decode("utf-8", errors="replace")
            print(f"[HTTP /send] {data[:200]!r}")
            # Parse simple form data: from=<name>&text=<text>
            params = {}
            for part in data.split("&"):
                if "=" in part:
                    k, v = part.split("=", 1)
                    params[k] = urllib.parse.unquote(v)
            print(f"[HTTP /send] parsed: {params}")
            self._send(200, b"OK")
        else:
            self._send(404, b"Not found")


def start_http_server(port):
    server = ThreadingHTTPServer(("0.0.0.0", port), MockHttpHandler)
    Thread(target=server.serve_forever, daemon=True).start()
    return server


async def start_mock_server(args):
    http_port = args.http_port or MOCK_HTTP_PORT
    ws_port = args.ws_port or MOCK_WS_PORT

    http_server = start_http_server(http_port)
    ws_server = await websockets.serve(mock_ws_handler, "0.0.0.0", ws_port)

    print(f"[MOCK] HTTP server on http://0.0.0.0:{http_port}")
    print(f"[MOCK] WebSocket server on ws://0.0.0.0:{ws_port}")
    print("[MOCK] Press Ctrl+C to stop")

    try:
        await asyncio.Future()  # run forever
    finally:
        ws_server.close()
        await ws_server.wait_closed()
        http_server.shutdown()


# ---------------------------------------------------------------------------
# Test client
# ---------------------------------------------------------------------------

def http_get(url, timeout=5):
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8")


def http_post(url, data, timeout=5):
    body = urllib.parse.urlencode(data).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")


async def run_ws_test(host, ws_port, http_port, name="TestUser", text="Hello from ws test"):
    uri = f"ws://{host}:{ws_port}/"
    http_url = f"http://{host}:{http_port}"

    results = {
        "http_ping": None,
        "http_send": None,
        "ws_connect": None,
        "ws_system": None,
        "ws_echo": None,
        "ws_name": None,
        "errors": [],
    }

    # HTTP tests
    try:
        status, body = http_get(f"{http_url}/ping")
        if status == 200 and body.strip() == "pong":
            results["http_ping"] = "OK"
        else:
            results["http_ping"] = f"FAIL ({status}: {body[:80]!r})"
    except Exception as e:
        results["http_ping"] = f"ERROR: {e}"
        results["errors"].append(str(e))

    try:
        status, body = http_post(
            f"{http_url}/send",
            {"from": name, "text": text},
        )
        if status == 200:
            results["http_send"] = f"OK ({status})"
        else:
            results["http_send"] = f"FAIL ({status}: {body[:80]!r})"
    except Exception as e:
        results["http_send"] = f"ERROR: {e}"
        results["errors"].append(str(e))

    # WebSocket tests
    try:
        async with websockets.connect(uri, open_timeout=10) as ws:
            results["ws_connect"] = "OK"

            # Wait for the system greeting.
            try:
                greeting = await asyncio.wait_for(ws.recv(), timeout=5)
                if greeting.startswith("System:"):
                    results["ws_system"] = f"OK ({greeting})"
                else:
                    results["ws_system"] = f"UNEXPECTED: {greeting[:80]!r}"
            except asyncio.TimeoutError:
                # Real ESP32 does not send a greeting on WebSocket open.
                results["ws_system"] = "NOT_EXPECTED (no greeting from real board)"
                pass

            # Send setName and wait for the server to register it.
            await ws.send(f"setName:{name}")
            results["ws_name"] = "SENT"
            # Real ESP32 has WS_MIN_MSG_INTERVAL_MS = 100; stay well clear of it.
            await asyncio.sleep(0.25)

            # Send a message with a unique id (new protocol) and wait for echo.
            # Real board strips the leading 'msg:' prefix and broadcasts '<name>:<id>:<text>'.
            msg_id = f"t{int(time.time()*1000)}"
            sent_frame = f"msg:{name}:{msg_id}:{text}"
            expected_echo = f"{name}:{msg_id}:{text}"
            await ws.send(sent_frame)

            deadline = time.time() + 10
            while time.time() < deadline:
                try:
                    reply = await asyncio.wait_for(ws.recv(), timeout=deadline - time.time())
                except asyncio.TimeoutError:
                    break

                if reply == expected_echo:
                    results["ws_echo"] = f"OK ({reply[:80]!r})"
                    break
                elif reply.startswith("System:"):
                    continue
                else:
                    results["ws_echo"] = f"UNEXPECTED: {reply[:80]!r}"
                    break

            if results["ws_echo"] is None:
                results["ws_echo"] = "TIMEOUT (no echo)"
    except Exception as e:
        results["ws_connect"] = f"ERROR: {e}"
        results["errors"].append(str(e))

    return results


def format_report(results, host, ws_port, http_port):
    lines = [
        "WebSocket/HTTP test report",
        "=" * 60,
        f"Target: {host}:{ws_port} (WS), {http_port} (HTTP)",
        "",
    ]
    for key, val in results.items():
        if key == "errors":
            continue
        lines.append(f"{key}: {val}")
    if results["errors"]:
        lines.append("")
        lines.append("Errors:")
        for e in results["errors"]:
            lines.append(f"  - {e}")
    lines.append("")
    overall = "OK" if all(
        v and (v.startswith("OK") or v == "SENT" or v.startswith("NOT_EXPECTED"))
        for k, v in results.items()
        if k not in ("errors",)
    ) else "FAIL"
    lines.append(f"Overall: {overall}")
    return "\n".join(lines)


async def run_test(args):
    host = args.host
    ws_port = args.ws_port or DEFAULT_WS_PORT
    http_port = args.http_port or DEFAULT_HTTP_PORT
    text = args.text
    name = args.name

    print(f"[TEST] Connecting to ws://{host}:{ws_port}/ and http://{host}:{http_port}")
    results = await run_ws_test(host, ws_port, http_port, name, text)
    report = format_report(results, host, ws_port, http_port)
    print(report)

    if args.report:
        with open(args.report, "w", encoding="utf-8") as f:
            f.write(report)
        print(f"Report written to: {args.report}")

    overall = "OK" if all(
        v and (v.startswith("OK") or v == "SENT" or v.startswith("NOT_EXPECTED"))
        for k, v in results.items()
        if k not in ("errors",)
    ) else "FAIL"
    return 0 if overall == "OK" else 1


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Mock ESP32 WS/HTTP server and test client")
    sub = parser.add_subparsers(dest="cmd", required=True)

    mock = sub.add_parser("mock", help="Start a local mock ESP32 server")
    mock.add_argument("--http-port", type=int, default=MOCK_HTTP_PORT)
    mock.add_argument("--ws-port", type=int, default=MOCK_WS_PORT)

    test = sub.add_parser("test", help="Test a real or mock ESP32 server")
    test.add_argument("--host", default="127.0.0.1", help="ESP32 / mock IP")
    test.add_argument("--ws-port", type=int, default=DEFAULT_WS_PORT)
    test.add_argument("--http-port", type=int, default=DEFAULT_HTTP_PORT)
    test.add_argument("--name", default="TestUser")
    test.add_argument("--text", default="Hello from ws test")
    test.add_argument("--report", default=None, help="Path to write report")

    args = parser.parse_args()

    if args.cmd == "mock":
        try:
            asyncio.run(start_mock_server(args))
        except KeyboardInterrupt:
            print("\n[MOCK] Stopped")
    elif args.cmd == "test":
        code = asyncio.run(run_test(args))
        sys.exit(code)


if __name__ == "__main__":
    main()
