#!/usr/bin/env python3
"""AFSK serial/radio multi-test bench.

Runs a suite of TX/RX tests over two serial ports (or radios). Each test sends a
message to the TX board, waits for "All blocks sent", then waits for the RX
board to print "FULL MESSAGE" and reports block/packet/CRC/preamble stats.

Example:
    /home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python \
        afsk_serial_test.py
"""

import argparse
import codecs
import queue
import re
import sys
import threading
import time

try:
    import serial
except ImportError as exc:  # pyserial is not part of the standard library
    print("This script requires 'pyserial'. Install it with: pip install pyserial", file=sys.stderr)
    raise


class PortReader:
    """Threaded UTF-8 line reader for a serial port.

    Uses an incremental UTF-8 decoder so characters split across read
    boundaries are not lost.
    """

    def __init__(self, port, baud, name):
        self.name = name
        self.ser = serial.Serial(
            port,
            baud,
            timeout=0.05,
            write_timeout=5,
            rtscts=False,
            dsrdtr=False,
        )
        # Do not let DTR/RTS reset the board on open.
        self.ser.setDTR(False)
        self.ser.setRTS(False)
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()

        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.line_queue = queue.Queue()
        self._all_lines = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._reader, daemon=True)
        self._thread.start()

    def _reader(self):
        buf = ""
        while not self._stop.is_set():
            try:
                data = self.ser.read(4096)
            except serial.SerialException:
                break
            if data:
                text = self.decoder.decode(data)
                if text:
                    buf += text
                    while "\n" in buf:
                        idx = buf.index("\n")
                        line = buf[:idx].rstrip("\r")
                        buf = buf[idx + 1 :]
                        with self._lock:
                            self._all_lines.append(line)
                        self.line_queue.put(line)
            else:
                time.sleep(0.01)
        # Flush any trailing data.
        if buf:
            with self._lock:
                self._all_lines.append(buf)
            self.line_queue.put(buf)

    def snapshot(self):
        """Return a marker for output captured so far."""
        with self._lock:
            return len(self._all_lines)

    def lines_since(self, marker):
        """Return all lines captured after the given marker."""
        with self._lock:
            return list(self._all_lines[marker:])

    def send(self, data: bytes):
        self.ser.write(data)

    def wait_for(self, pattern: str, timeout: float, start_time: float = None):
        """Return (found, line) once a line containing *pattern* is seen."""
        if start_time is None:
            start_time = time.time()
        deadline = start_time + timeout
        while time.time() < deadline:
            try:
                line = self.line_queue.get(timeout=0.1)
                if pattern in line:
                    return True, line
            except queue.Empty:
                continue
        return False, None

    def drain(self, timeout: float = 0.3):
        """Empty the live line queue."""
        lines = []
        try:
            while True:
                lines.append(self.line_queue.get(timeout=timeout))
        except queue.Empty:
            pass
        return lines

    def close(self):
        self._stop.set()
        self._thread.join(timeout=2)
        try:
            self.ser.close()
        except Exception:
            pass


def build_test_cases():
    """Build the default AFSK test suite.

    Lengths are in characters; the firmware prints bytes/blocks too.
    """
    word = "Проверка"  # 8 Cyrillic characters, 16 bytes UTF-8
    return [
        ("short_ascii", "A", 30, 30),
        ("cyr_1", "П", 30, 30),
        ("cyr_25", word * 3 + "П", 30, 30),
        ("cyr_50", word * 6 + "Пр", 60, 60),
        ("cyr_200", word * 25, 120, 180),
        ("cyr_255", word * 31 + "Проверк", 180, 240),
        ("cyr_300", word * 37 + "Пров", 240, 300),
        ("cyr_600", word * 75, 300, 360),
    ]


def parse_tx_blocks(lines):
    for line in lines:
        m = re.search(r"Message:\s+(\d+)\s+bytes,\s+Blocks:\s+(\d+)", line)
        if m:
            return int(m.group(2))
    return None


def parse_rx_stats(lines):
    packets = crc = aborted = None
    for line in lines:
        m = re.search(
            r"Stats:\s+Packets:\s+(\d+)\s+\|\s+CRC errors:\s+(\d+)\s+\|\s+Frames aborted:\s+(\d+)",
            line,
        )
        if m:
            packets, crc, aborted = (int(g) for g in m.groups())
    return packets, crc, aborted


def parse_full_message(lines):
    for line in lines:
        m = re.search(r"FULL MESSAGE:\s+(\d+)\s+bytes\s+in\s+(\d+)\s+blocks", line)
        if m:
            return int(m.group(1)), int(m.group(2))
    return None, None


def parse_preamble_sync(lines):
    """Return the final complete preamble lock line, e.g. '480/480 (100%, glitches: 0)'."""
    final = None
    for line in lines:
        m = re.search(
            r"\[PREAMBLE\]\s+(\d+)/(\d+)\s+\(conf:\s+(\d+)%,\s+glitches:\s+(\d+)\)",
            line,
        )
        if m:
            cur, total, conf, glitches = m.groups()
            if int(cur) == int(total):
                final = f"{cur}/{total} ({conf}%, glitches: {glitches})"
    return final


def format_test_section(
    name,
    msg,
    status,
    tx_blocks,
    rx_packets,
    rx_crc,
    rx_aborted,
    preamble_sync,
    full_bytes,
    full_blocks,
    tx_lines,
    rx_lines,
):
    preview = msg if len(msg) <= 80 else msg[:80] + "..."
    lines = [
        f"## {name}",
        f"Status: {status}",
        f"Sent ({len(msg)} chars, {len(msg.encode('utf-8'))} bytes): {preview}",
        f"TX blocks: {tx_blocks if tx_blocks is not None else 'None'}",
        f"RX packets: {rx_packets if rx_packets is not None else 'None'}, "
        f"CRC errors: {rx_crc if rx_crc is not None else 'None'}, "
        f"Frames aborted: {rx_aborted if rx_aborted is not None else 'None'}",
        f"Preamble sync: {preamble_sync if preamble_sync else 'None'}",
        f"RX full message: {full_bytes if full_bytes is not None else 'None'} bytes in "
        f"{full_blocks if full_blocks is not None else 'None'} blocks",
        "",
        "--- TX raw output ---",
    ]
    lines.extend(tx_lines)
    lines.append("")
    lines.append("--- RX raw output ---")
    lines.extend(rx_lines)
    lines.append("")
    return "\n".join(lines)


def run_test(name, msg, tx, rx, tx_timeout, rx_timeout):
    """Run a single AFSK test case and return its formatted section."""
    msg_bytes = msg.encode("utf-8")

    # Discard any chatter that arrived between tests.
    tx.drain(timeout=0.2)
    rx.drain(timeout=0.2)

    tx_snapshot = tx.snapshot()
    rx_snapshot = rx.snapshot()

    start = time.time()
    print(f"[{time.strftime('%H:%M:%S')}] [{name}] Sending {len(msg)} chars / {len(msg_bytes)} bytes ...")
    tx.send(msg_bytes + b"\n")

    tx_ok, _ = tx.wait_for("All blocks sent", tx_timeout, start)
    if tx_ok:
        print(f"[{time.strftime('%H:%M:%S')}] [{name}] TX done, waiting RX ...")
        rx_ok, _ = rx.wait_for("FULL MESSAGE", rx_timeout, start)
    else:
        rx_ok = False
        print(f"[{time.strftime('%H:%M:%S')}] [{name}] TX timeout")

    # Give any trailing lines time to arrive.
    time.sleep(1)
    tx.drain(timeout=0.3)
    rx.drain(timeout=0.3)

    tx_lines = tx.lines_since(tx_snapshot)
    rx_lines = rx.lines_since(rx_snapshot)

    tx_blocks = parse_tx_blocks(tx_lines)
    rx_packets, rx_crc, rx_aborted = parse_rx_stats(rx_lines)
    full_bytes, full_blocks = parse_full_message(rx_lines)
    preamble_sync = parse_preamble_sync(rx_lines)

    if not tx_ok:
        status = 'TX timeout (no "All blocks sent")'
    elif not rx_ok:
        status = "RX timeout (no full message)"
    elif full_bytes != len(msg_bytes) or full_blocks is None:
        status = f"RX mismatch ({full_bytes} bytes / {full_blocks} blocks)"
    else:
        status = "OK"

    print(f"[{time.strftime('%H:%M:%S')}] [{name}] Status: {status}")

    return format_test_section(
        name,
        msg,
        status,
        tx_blocks,
        rx_packets,
        rx_crc,
        rx_aborted,
        preamble_sync,
        full_bytes,
        full_blocks,
        tx_lines,
        rx_lines,
    )


def main():
    parser = argparse.ArgumentParser(
        description="AFSK multi-test bench for TX/RX serial/radio link."
    )
    parser.add_argument("--tx-port", default="/dev/ttyUSB0", help="TX serial port")
    parser.add_argument("--rx-port", default="/dev/ttyUSB1", help="RX serial port")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--report", default="/tmp/afsk_test_report.txt", help="Report file")
    parser.add_argument(
        "--tests",
        default="all",
        help="Comma-separated test names, or 'all' (default: all)",
    )
    parser.add_argument(
        "--stop-on-fail",
        action="store_true",
        help="Stop after the first failing test",
    )
    args = parser.parse_args()

    all_tests = build_test_cases()
    if args.tests == "all":
        selected = all_tests
    else:
        names = set(args.tests.split(","))
        selected = [t for t in all_tests if t[0] in names]
        if not selected:
            print(f"No matching tests. Available: {', '.join(t[0] for t in all_tests)}", file=sys.stderr)
            sys.exit(1)

    tx = PortReader(args.tx_port, args.baud, "TX")
    rx = PortReader(args.rx_port, args.baud, "RX")

    # Wait for boards to finish booting and print startup chatter.
    time.sleep(2)
    tx.drain(timeout=0.3)
    rx.drain(timeout=0.3)

    report_sections = [
        "AFSK serial/radio test report",
        "=" * 120,
        "",
    ]

    try:
        for name, msg, tx_to, rx_to in selected:
            section = run_test(name, msg, tx, rx, tx_to, rx_to)
            report_sections.append(section)
            report_sections.append("")
            if args.stop_on_fail and not section.startswith(f"## {name}\nStatus: OK"):
                break
    finally:
        tx.close()
        rx.close()

    report = "\n".join(report_sections)
    with open(args.report, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"\nReport written to: {args.report}")


if __name__ == "__main__":
    main()
