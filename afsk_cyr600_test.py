#!/usr/bin/env python3
"""Focused AFSK serial/radio test: cyr_600.

600 Cyrillic characters ("Проверка" * 75) = 1200 bytes UTF-8 = 24 blocks of 50 bytes.
The script waits long enough for the full TX (~2.7 min on the air) plus RX assembly.

Example:
    /home/dima/.espressif/python_env/idf6.0_py3.12_env/bin/python afsk_cyr600_test.py
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


def build_cyr600():
    """Return the cyr_600 test string: 600 Cyrillic characters, 1200 bytes."""
    word = "Проверка"  # 8 Cyrillic characters, 16 bytes UTF-8
    return word * 75  # 600 chars / 1200 bytes


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


def format_report(
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
        "AFSK focused test report: cyr_600",
        "=" * 120,
        "",
        "## cyr_600",
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


def main():
    parser = argparse.ArgumentParser(
        description="Focused AFSK test: 600 Cyrillic characters (1200 bytes, 24 blocks)."
    )
    parser.add_argument("--tx-port", default="/dev/ttyUSB0", help="TX serial port")
    parser.add_argument("--rx-port", default="/dev/ttyUSB1", help="RX serial port")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument(
        "--tx-timeout", type=float, default=300, help="Seconds to wait for 'All blocks sent'"
    )
    parser.add_argument(
        "--rx-timeout", type=float, default=360, help="Seconds to wait for 'FULL MESSAGE'"
    )
    parser.add_argument(
        "--report", default="/tmp/afsk_cyr600_report.txt", help="Where to write the report"
    )
    args = parser.parse_args()

    msg = build_cyr600()
    msg_bytes = msg.encode("utf-8")
    assert len(msg) == 600
    assert len(msg_bytes) == 1200

    print(f"Test cyr_600: {len(msg)} chars / {len(msg_bytes)} bytes / "
          f"{len(msg_bytes) // 50} expected blocks")

    tx = PortReader(args.tx_port, args.baud, "TX")
    rx = PortReader(args.rx_port, args.baud, "RX")

    try:
        # Discard startup chatter.
        time.sleep(1)
        tx.drain(timeout=0.2)
        rx.drain(timeout=0.2)

        tx_snapshot = tx.snapshot()
        rx_snapshot = rx.snapshot()

        start = time.time()
        print(f"[{time.strftime('%H:%M:%S')}] Sending message...")
        tx.send(msg_bytes + b"\n")

        tx_ok, _ = tx.wait_for("All blocks sent", args.tx_timeout, start)
        if tx_ok:
            print(f"[{time.strftime('%H:%M:%S')}] TX reported all blocks sent")
            rx_ok, _ = rx.wait_for("FULL MESSAGE", args.rx_timeout, start)
        else:
            rx_ok = False
            print(f"[{time.strftime('%H:%M:%S')}] TX timeout")

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

        print(f"Status: {status}")
        print(f"TX blocks: {tx_blocks}")
        print(f"RX packets: {rx_packets}, CRC errors: {rx_crc}, Frames aborted: {rx_aborted}")
        print(f"RX full message: {full_bytes} bytes in {full_blocks} blocks")
        print(f"Preamble sync: {preamble_sync}")

        report = format_report(
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

        with open(args.report, "w", encoding="utf-8") as f:
            f.write(report)
        print(f"Report written to: {args.report}")

    finally:
        tx.close()
        rx.close()


if __name__ == "__main__":
    main()
