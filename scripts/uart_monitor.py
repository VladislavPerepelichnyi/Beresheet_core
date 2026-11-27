#!/usr/bin/env python3
"""
Read the board's serial output and print it.

Deliberately dependency-free: opens the tty directly rather than requiring
pyserial, since the port is already configured by stty in the Makefile.

Usage:  uart_monitor.py <device> <baud> <seconds> [--quiet-exit]
"""

import os
import sys
import termios
import time


def configure(fd, baud):
    baud_const = {
        9600:   termios.B9600,
        19200:  termios.B19200,
        38400:  termios.B38400,
        57600:  termios.B57600,
        115200: termios.B115200,
    }.get(baud)
    if baud_const is None:
        sys.exit(f"uart_monitor: unsupported baud {baud}")

    a = termios.tcgetattr(fd)
    # iflag, oflag, cflag, lflag, ispeed, ospeed, cc
    a[0] = 0                                       # no input processing
    a[1] = 0                                       # no output processing
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[3] = 0                                       # raw, no echo
    a[4] = baud_const
    a[5] = baud_const
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIFLUSH)


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    dev, baud, secs = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])

    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    configure(fd, baud)

    deadline = time.time() + secs
    total = 0
    try:
        while time.time() < deadline:
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                time.sleep(0.01)
                continue
            if chunk:
                total += len(chunk)
                sys.stdout.write(chunk.decode('utf-8', errors='replace'))
                sys.stdout.flush()
            else:
                time.sleep(0.01)
    finally:
        os.close(fd)

    print(f"\n[uart_monitor: {total} bytes in {secs:g}s]", file=sys.stderr)


if __name__ == "__main__":
    main()
