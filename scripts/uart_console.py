#!/usr/bin/env python3
"""
Minimal interactive serial console, for machines without tio or picocom.

Everything typed is sent to the board; everything received is printed. The
local terminal is put in raw mode so control characters (Ctrl-C, Tab, arrows)
reach the remote shell. Press Ctrl-] to quit.

Usage:  uart_console.py <device> <baud>
"""

import os
import select
import sys
import termios
import tty

QUIT = b"\x1d"                                          # Ctrl-]

SPEEDS = {9600: termios.B9600, 19200: termios.B19200, 38400: termios.B38400,
          57600: termios.B57600, 115200: termios.B115200}


def open_port(dev, baud):
    if baud not in SPEEDS:
        sys.exit(f"uart_console: unsupported baud {baud}")
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0                                            # iflag: raw input
    a[1] = 0                                            # oflag: raw output
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL  # 8N1, no modem control
    a[3] = 0                                            # lflag: no echo
    a[4] = a[5] = SPEEDS[baud]
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    port = open_port(sys.argv[1], int(sys.argv[2]))
    stdin = sys.stdin.fileno()
    saved = termios.tcgetattr(stdin) if os.isatty(stdin) else None
    print(f"[{sys.argv[1]} at {sys.argv[2]} baud, Ctrl-] to quit]\r")
    try:
        if saved:
            tty.setraw(stdin)
        while True:
            ready, _, _ = select.select([port, stdin], [], [])
            if port in ready:
                data = os.read(port, 4096)
                if data:
                    os.write(sys.stdout.fileno(), data)
            if stdin in ready:
                data = os.read(stdin, 1024)
                if not data or QUIT in data:
                    break
                os.write(port, data)
    finally:
        if saved:
            termios.tcsetattr(stdin, termios.TCSADRAIN, saved)
        os.close(port)
        print("\n[console closed]")


if __name__ == "__main__":
    main()
