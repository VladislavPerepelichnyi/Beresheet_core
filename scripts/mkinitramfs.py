#!/usr/bin/env python3
"""
Build the initramfs cpio for the custom_riscv board.

    mkinitramfs.py <busybox-install-dir> <skeleton-dir> <gen_init_cpio> <out.gz>

Why this exists rather than a `find | cpio -o` pipeline:

  * Every file in the image has to be owned by root. `cpio` run as an ordinary
    user stamps uid 1000 on everything, and `--owner=0:0` fixes the numbers but
    still cannot create a device node.

  * /dev/console has to be a real character device in the image. The kernel
    opens it and dups it onto init's fds 0, 1 and 2; if it is missing, init
    starts with no stdio and the machine boots to a console that prints nothing
    while being perfectly healthy. That failure looks exactly like a hang.

The kernel ships `usr/gen_init_cpio` for precisely this: it reads a manifest of
what the image should contain, with explicit modes and uids, and fabricates it
all without needing root. We generate the manifest and hand it over.

Manifest grammar (from the kernel's usr/gen_init_cpio.c):

    dir   <name> <mode> <uid> <gid>
    file  <name> <source> <mode> <uid> <gid>
    nod   <name> <mode> <uid> <gid> <c|b> <maj> <min>
    slink <name> <target> <mode> <uid> <gid>

Order matters: a directory must be listed before anything inside it, so the
walk below is sorted and parents always precede children.
"""

import os
import subprocess
import sys

# Directories the image needs that no source tree provides. Mount points, and
# the two writable spots a shell expects to find.
EXTRA_DIRS = ["/proc", "/sys", "/dev", "/tmp", "/root", "/var", "/run", "/etc/init.d"]

# The four nodes that have to exist before rcS can mount devtmpfs over them.
#
#   console  init's stdio, and the reason this script does not use cpio
#   null     anything redirecting to /dev/null before /dev is mounted
#   tty      the shell's controlling terminal
#   ttyS0    the actual UART, in case console is pointed elsewhere
NODES = [
    ("/dev/console", 0o600, "c", 5, 1),
    ("/dev/null", 0o666, "c", 1, 3),
    ("/dev/tty", 0o666, "c", 5, 0),
    ("/dev/ttyS0", 0o600, "c", 4, 64),
    # kmsg is the diagnostic channel, not a console. A write to it goes through
    # printk, which reaches the UART via uart_console_write() - the polled path
    # that works even when the tty TX path is dead. It is the only way a
    # userspace process can prove it is alive on a machine whose tty output
    # never drains.
    ("/dev/kmsg", 0o622, "c", 1, 11),
    # hvc0, so the SBI console is addressable by name as well as through
    # /dev/console.
    ("/dev/hvc0", 0o600, "c", 229, 0),
]

# Files that must be executable even though the repository may not have the bit
# set on them (a fresh clone, a copy through a filesystem without permissions).
FORCE_EXEC = {"/etc/init.d/rcS", "/etc/init.d/mountall"}


def walk(root, lines, seen):
    """Emit manifest lines for every entry under `root`, parents first."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel = "/" + os.path.relpath(dirpath, root)
        if rel == "/.":
            rel = ""

        for d in dirnames:
            name = f"{rel}/{d}"
            if name not in seen:
                seen.add(name)
                lines.append(f"dir {name} 0755 0 0")

        for f in sorted(filenames):
            name = f"{rel}/{f}"
            src = os.path.join(dirpath, f)
            if name in seen:
                continue
            seen.add(name)

            if os.path.islink(src):
                # BusyBox's install is a forest of symlinks to one binary, so
                # this branch carries almost the whole userspace.
                lines.append(f"slink {name} {os.readlink(src)} 0777 0 0")
            else:
                mode = 0o755 if (os.access(src, os.X_OK) or name in FORCE_EXEC) else 0o644
                lines.append(f"file {name} {src} 0{mode:o} 0 0")


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__.strip().splitlines()[2].strip())

    bb_install, skel, gen_init_cpio, out = sys.argv[1:5]

    for p, what in ((bb_install, "busybox install"), (skel, "skeleton"),
                    (gen_init_cpio, "gen_init_cpio")):
        if not os.path.exists(p):
            sys.exit(f"mkinitramfs: no {what} at {p}")

    lines, seen = [], set()

    # Mount points and writable directories first, so that a file landing in
    # one of them later never has to create its own parent.
    for d in EXTRA_DIRS:
        parts = d.strip("/").split("/")
        for i in range(len(parts)):
            name = "/" + "/".join(parts[: i + 1])
            if name not in seen:
                seen.add(name)
                lines.append(f"dir {name} 0755 0 0")

    walk(bb_install, lines, seen)

    # The skeleton is walked second and wins nothing: `seen` means the busybox
    # install cannot be overwritten by accident. Nothing in the skeleton
    # collides with it today, and if that changes the collision should be a
    # deliberate edit rather than a silent overwrite decided by walk order.
    for dirpath, dirnames, filenames in os.walk(skel):
        dirnames.sort()
        rel = "/" + os.path.relpath(dirpath, skel)
        if rel == "/.":
            rel = ""
        for d in sorted(dirnames):
            name = f"{rel}/{d}"
            if name not in seen:
                seen.add(name)
                lines.append(f"dir {name} 0755 0 0")
        for f in sorted(filenames):
            name = f"{rel}/{f}"
            if name in seen:
                continue
            seen.add(name)
            src = os.path.join(dirpath, f)
            mode = 0o755 if (os.access(src, os.X_OK) or name in FORCE_EXEC) else 0o644
            lines.append(f"file {name} {src} 0{mode:o} 0 0")

    for name, mode, kind, maj, minor in NODES:
        lines.append(f"nod {name} 0{mode:o} 0 0 {kind} {maj} {minor}")

    # The kernel looks for /init in an initramfs. BusyBox installs its init as
    # /sbin/init, so the entry point is a symlink - which also means bootargs
    # can say either path.
    if "/init" not in seen:
        lines.append("slink /init /sbin/init 0777 0 0")

    if not any(l.startswith("slink /sbin/init ") or l.startswith("file /sbin/init ")
               for l in lines):
        sys.exit("mkinitramfs: the busybox install has no /sbin/init - "
                 "check CONFIG_INIT in the busybox config")

    manifest = out + ".manifest"
    with open(manifest, "w") as f:
        f.write("\n".join(lines) + "\n")

    cpio = subprocess.run([gen_init_cpio, manifest], stdout=subprocess.PIPE, check=True)
    gz = subprocess.run(["gzip", "-9", "-n"], input=cpio.stdout,
                        stdout=subprocess.PIPE, check=True)
    with open(out, "wb") as f:
        f.write(gz.stdout)

    # The uncompressed archive as well, for CONFIG_INITRAMFS_SOURCE. The kernel
    # build compresses it itself, and gen_initramfs.sh will not accept a .gz
    # that it did not make. Keeping both means the same tree can be shipped
    # either as a separate file on the card or built into the Image.
    raw = out[:-3] if out.endswith(".gz") else out + ".cpio"
    with open(raw, "wb") as f:
        f.write(cpio.stdout)

    n_files = sum(1 for l in lines if l.startswith("file "))
    n_links = sum(1 for l in lines if l.startswith("slink "))
    print(f"initramfs: {raw}")
    print(f"initramfs: {len(cpio.stdout):,} bytes -> {len(gz.stdout):,} gzipped"
          f"  ({n_files} files, {n_links} links, {len(NODES)} nodes)")
    print(f"           uncompressed size is what it costs in RAM, "
          f"not the gzipped one")


if __name__ == "__main__":
    main()
