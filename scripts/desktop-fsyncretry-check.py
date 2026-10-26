#!/usr/bin/env python3
"""Failed write-back and its retries on pc-ubuntu, without the engine.

What does Linux leave after an fdatasync() fails with EIO, and what does a
retry do? One 4 KiB page of a 1 MiB file, stored through a MAP_SHARED mapping
and made durable with fdatasync(), as MappedFileRegion's boundary does (Rebello
et al., ATC '20; docs/persistent-backends.md, "A failed write below ext4 and
XFS: the same-boot reopen replays a record the disk lacks").
  scripts/desktop-fsyncretry-check.py check [--dir DIR]
  sudo python3 -I scripts/desktop-fsyncretry-check.py run --yes-inject-io-errors [ext4] [xfs]

Steps, with each prediction under the fault (check, with no fault, predicts
every sync ok and the cache and the device equal):
  0  the page holds A, read through the cache and with O_DIRECT
  1  the page's 8 sectors sent to the dm error target; store B; fdatasync: EIO
  2  fdatasync again, the naive retry: ok, while the device still fails
  3  the device restored; fdatasync: ok; the page reads B through the cache
     and A with O_DIRECT; a new descriptor's fdatasync, what a reopen sees: ok
  4  store B again, the rewrite retry; fdatasync: ok; the device holds B
  5  the error again, left in place: three times store C and fdatasync: EIO
  6  the device restored; munmap; posix_fadvise(DONTNEED): the cache reads B,
     the device's copy

run, per file system (ext4; XFS only if mkfs.xfs exists): a sparse 512 MiB
image in a new directory under /var/tmp, attached with losetup
--direct-io=on, a new dm device with one linear target over it, a fresh file
system with default options, mounted in that directory. Nothing else is
touched. Everything is torn down on exit, failure or interrupt, with the
linear table restored first. The fault is desktop-fsyncfail-check.sh's (its
header says why not dm-flakey): a table that maps exactly the page's sectors
to `error` and the rest linearly, read back after every load.

Reading the kernel log. Before each step the script writes a marker line to
/dev/kmsg, so each kernel message in kmsg.txt lies between the markers of the
step that caused it; journald's timestamps say when it read a message, not
when the kernel printed it. ext4's "I/O error ... starting block" can name the
block after the failed one: ext4_end_bio() reads the bio's sector at
completion, after dm has trimmed the bio past each target's part (v7.0
fs/ext4/page-io.c ext4_end_bio, drivers/md/dm.c dm_split_and_process_bio).
ext4's "Buffer I/O error" lines list every block the failed write covered, not
only the failed page's, up to printk's limit of 10. On XFS the file lies near
the device's start, where udev's probe after each table change reads; its
failed reads appear as "async page read" and are reads of the device, not of
the file.

Results, owned by the checkout's owner: results/<UTC>-sean-tan-PC-fsyncretry-*/
with this script, provenance.txt, run.log, summary.txt and, per file system,
dm-tables.txt, mapping.txt, fs.txt and kmsg.txt. run refuses unless this
script is committed unchanged, so the recorded commit describes it.
"""
import argparse
import datetime
import errno
import fcntl
import hashlib
import mmap
import os
import pwd
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import traceback

PAGE = 4096
FILE_BYTES = 1 << 20
TEST_OFFSET = 1 * PAGE
IMAGE_BYTES = 512 << 20  # mkfs.xfs refuses less than 300 MiB
FS_IOC_FIEMAP = 0xC020660B
FIEMAP_FLAG_SYNC = 0x1
# UNKNOWN, DELALLOC, ENCODED, NOT_ALIGNED, DATA_INLINE, DATA_TAIL, UNWRITTEN
FIEMAP_BAD_FLAGS = 0x2 | 0x4 | 0x8 | 0x100 | 0x200 | 0x400 | 0x800
SELF = os.path.realpath(__file__)
REPO = os.path.dirname(os.path.dirname(SELF))
REL = os.path.relpath(SELF, REPO)
TOOLS = ("losetup", "dmsetup", "mkfs.ext4", "mount", "umount", "findmnt", "git")
NOISE = ("[UFW ", "apparmor=")


class Out:
    log = None      # run.log, while run writes results
    owner = None    # (uid, gid) of the checkout's owner, under run
    markers = False # write step markers to /dev/kmsg


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    if Out.log:
        Out.log.write(line + "\n")
        Out.log.flush()


def own(path):
    if Out.owner:
        os.chown(path, *Out.owner)


def write(path, text):
    with open(path, "w") as f:
        f.write(text)
    own(path)


rows = []  # (step, got, predicted) for the current case


def check(label, got, want):
    rows.append((label, got, want))
    say(f"  {label:<52} {got:<10} predicted {want:<8} {'' if got == want else '<-- differs'}")


def run(*cmd, stdin=None):
    return subprocess.run(cmd, input=stdin, check=True, text=True,
                          capture_output=True).stdout.strip()


def capture(*cmd):
    """stdout and stderr of a command for the record; never raises."""
    try:
        r = subprocess.run(cmd, text=True, capture_output=True)
    except OSError as e:
        return f"({' '.join(cmd)}: {e})"
    out = (r.stdout + r.stderr).strip()
    return out if r.returncode == 0 else f"{out}\n({' '.join(cmd)}: exit {r.returncode})"


def git(*args):
    """git in the checkout, as its owner under run: root would trip git's
    ownership check, and --no-optional-locks keeps git from rewriting the index."""
    cmd = ("git", "-C", REPO, "--no-optional-locks") + args
    if not Out.owner:
        return subprocess.run(cmd, text=True, capture_output=True)
    uid, gid = Out.owner
    env = {"HOME": pwd.getpwuid(uid).pw_dir, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
    return subprocess.run(cmd, user=uid, group=gid, extra_groups=[], env=env,
                          text=True, capture_output=True)


def mark(text):
    """A line in the kernel log, so kernel messages can be placed between
    steps. Opened per line: writes to /dev/kmsg are rate-limited per open file
    and dropped silently past the limit (v7.0 kernel/printk/printk.c,
    devkmsg_open and devkmsg_write)."""
    if not Out.markers:
        return
    try:
        fd = os.open("/dev/kmsg", os.O_WRONLY)
    except OSError:
        return
    try:
        os.write(fd, f"fsyncretry: {text}\n".encode())
    except OSError:
        pass
    finally:
        os.close(fd)


class Kmsg:
    """The kernel's records from the moment of construction on, with the
    kernel's own timestamps."""

    def __init__(self):
        self.fd = os.open("/dev/kmsg", os.O_RDONLY | os.O_NONBLOCK)
        os.lseek(self.fd, 0, os.SEEK_END)

    def drain(self):
        recs = []
        while True:
            try:
                raw = os.read(self.fd, 8192)
            except BlockingIOError:
                break
            except BrokenPipeError:
                recs.append((None, "(records overwritten before they were read)"))
                continue
            recs.append(parse_record(raw))
        os.close(self.fd)
        return recs


def parse_record(raw):
    """One /dev/kmsg record, "prio,seq,usec,flags;message" and then any
    " KEY=value" lines: (seconds since boot or None, message)."""
    head, _, rest = raw.decode("utf-8", "replace").partition(";")
    fields = head.split(",")
    ts = int(fields[2]) / 1e6 if len(fields) > 2 and fields[2].isdigit() else None
    return ts, rest.split("\n", 1)[0]


def fdatasync(fd):
    try:
        os.fdatasync(fd)
        return "ok"
    except OSError as e:
        return errno.errorcode.get(e.errno, str(e.errno))


def content(page):
    for ch in b"ABC":
        if page == bytes([ch]) * PAGE:
            return chr(ch)
    return "other"


def read_direct(path, off):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
    try:
        buf = mmap.mmap(-1, PAGE)  # page-aligned, as O_DIRECT needs
        if os.preadv(fd, [buf], off) != PAGE:
            raise SystemExit("short O_DIRECT read")
        return bytes(buf)
    finally:
        os.close(fd)


def physical_offset(fd, logical):
    """Device byte offset of [logical, logical + PAGE), and the extent."""
    buf = bytearray(struct.pack("=QQLLLL", logical, PAGE, FIEMAP_FLAG_SYNC, 0, 1, 0) + bytes(56))
    fcntl.ioctl(fd, FS_IOC_FIEMAP, buf)
    if struct.unpack_from("=L", buf, 20)[0] != 1:
        raise SystemExit("FIEMAP: expected one extent")
    fe_logical, fe_physical, fe_length = struct.unpack_from("=QQQ", buf, 32)
    fe_flags = struct.unpack_from("=L", buf, 72)[0]
    if fe_flags & FIEMAP_BAD_FLAGS:
        raise SystemExit(f"FIEMAP: extent flags {fe_flags:#x}: not a plain written extent")
    if not fe_logical <= logical < logical + PAGE <= fe_logical + fe_length:
        raise SystemExit("FIEMAP: extent does not cover the page")
    phys = fe_physical + (logical - fe_logical)
    if phys % PAGE:
        raise SystemExit("FIEMAP: page not 4 KiB aligned on the device")
    extent = (f"extent logical {fe_logical} physical {fe_physical} "
              f"length {fe_length} flags {fe_flags:#x}")
    return phys, extent


def steps(path, arm, disarm, fault, mapping=None):
    with open(path, "wb") as f:
        f.write(b"A" * FILE_BYTES)
        f.flush()
        os.fsync(f.fileno())
    fd = os.open(path, os.O_RDWR)
    m = None
    # Closed on every path, so that after a failure the teardown's umount does
    # not find the file system busy.
    try:
        phys, extent = physical_offset(fd, TEST_OFFSET)
        say(f"  page at file offset {TEST_OFFSET}, device byte {phys} (sector {phys // 512})")
        if mapping is not None:
            mapping += [f"file_offset {TEST_OFFSET}", f"page_bytes {PAGE}", extent,
                        f"device_byte {phys}", f"fail_sector {phys // 512}", "fail_sectors 8"]
        m = mmap.mmap(fd, FILE_BYTES, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)

        def store(ch):
            m[TEST_OFFSET:TEST_OFFSET + PAGE] = ch * PAGE

        def show(label, cache, device):
            check(f"{label}: cache", content(os.pread(fd, PAGE, TEST_OFFSET)), cache)
            check(f"{label}: device (O_DIRECT)", content(read_direct(path, TEST_OFFSET)), device)

        E = "EIO" if fault else "ok"
        mark("step 0: reads")
        show("0 before", "A", "A")
        mark("step 1: arm")
        arm(phys)
        mark("step 1: store B, fdatasync")
        store(b"B")
        check("1 store B, fdatasync", fdatasync(fd), E)
        mark("step 2: fdatasync again")
        check("2 fdatasync again (naive retry)", fdatasync(fd), "ok")
        mark("step 3: disarm")
        disarm()
        mark("step 3: fdatasync, reads, new descriptor's fdatasync")
        check("3 device restored, fdatasync", fdatasync(fd), "ok")
        show("3", "B", "A" if fault else "B")
        fd2 = os.open(path, os.O_RDWR)
        check("3 new descriptor, fdatasync", fdatasync(fd2), "ok")
        os.close(fd2)
        mark("step 4: store B again, fdatasync, reads")
        store(b"B")
        check("4 store B again (rewrite retry), fdatasync", fdatasync(fd), "ok")
        show("4", "B", "B")
        mark("step 5: arm")
        arm(phys)
        for i in range(3):
            mark(f"step 5.{i + 1}: store C, fdatasync")
            store(b"C")
            check(f"5.{i + 1} lasting error: store C, fdatasync", fdatasync(fd), E)
        mark("step 5: disarm, reads")
        disarm()
        show("5", "C", "B" if fault else "C")
        mark("step 6: munmap, fadvise, read")
        m.close()
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        check("6 munmap, fadvise(DONTNEED): cache", content(os.pread(fd, PAGE, TEST_OFFSET)),
              "B" if fault else "C")
        mark("steps done")
    finally:
        if m is not None:
            m.close()
        os.close(fd)


def real_case(fstype, out_dir):
    say(f"==== {fstype}")
    name = "fsyncretry-" + secrets.token_hex(4)
    dev = "/dev/mapper/" + name
    if os.path.exists(dev):
        raise SystemExit(f"{dev} exists")
    case_dir = os.path.join(out_dir, fstype)
    os.mkdir(case_dir)
    own(case_dir)
    kmsg = Kmsg()
    mark(f"{fstype} case begins")
    tables, mapping, facts = [], [], []
    tmp = tempfile.mkdtemp(prefix="fsyncretry-", dir="/var/tmp")
    img, mnt = os.path.join(tmp, "disk.img"), os.path.join(tmp, "mnt")
    sectors = IMAGE_BYTES // 512
    loop = None
    created = mounted = False
    try:
        with open(img, "wb") as f:
            f.truncate(IMAGE_BYTES)
        loop = run("losetup", "--find", "--show", "--direct-io=on", img)
        facts.append("---- loop\n" + capture("losetup", "-l", "-O", "NAME,BACK-FILE,DIO,LOG-SEC", loop))
        # Tables name the loop by major:minor, the form `dmsetup table` prints
        # back, so the read-back comparison below is exact.
        rdev = os.stat(loop).st_rdev
        loop_mm = f"{os.major(rdev)}:{os.minor(rdev)}"
        linear = f"0 {sectors} linear {loop_mm} 0\n"
        run("dmsetup", "create", name, stdin=linear)
        created = True

        def check_table(table, label):
            got = run("dmsetup", "table", name)
            tables.append(f"---- {label}\n{got}")
            if got.split() != table.split():
                raise SystemExit(f"dm table differs after {label}")

        def load(table, label):
            run("dmsetup", "load", name, stdin=table)
            run("dmsetup", "suspend", name)
            run("dmsetup", "resume", name)
            check_table(table, label)

        def arm(phys):
            s = phys // 512
            load(f"0 {s} linear {loop_mm} 0\n{s} 8 error\n"
                 f"{s + 8} {sectors - s - 8} linear {loop_mm} {s + 8}\n", "armed")

        # Before any fault: a table that does not read back stops the run here.
        check_table(linear, "created: all linear")
        if fstype == "ext4":
            mkfs = ("mkfs.ext4", "-q", "-F", "-b", "4096",
                    "-E", "lazy_itable_init=0,lazy_journal_init=0", dev)
        else:
            mkfs = ("mkfs.xfs", "-q", "-f", dev)
        run(*mkfs)
        facts.append("---- mkfs\n" + " ".join(mkfs))
        os.mkdir(mnt)
        run("mount", dev, mnt)
        mounted = True
        mounted_as = run("findmnt", "-no", "SOURCE,FSTYPE,OPTIONS", mnt)
        facts.append("---- mounted\n" + mounted_as)
        say("  " + mounted_as.split(None, 1)[1])
        steps(os.path.join(mnt, "region"), arm,
              lambda: load(linear, "restored: all linear"), True, mapping)
    finally:
        # Never raises, so an error above is not masked; restores the linear
        # table before anything else touches the file system.
        def quiet(*cmd, stdin=None):
            return subprocess.run(cmd, input=stdin, text=True, capture_output=True)

        left = []
        if created:
            for cmd in (("dmsetup", "load", name), ("dmsetup", "suspend", name),
                        ("dmsetup", "resume", name)):
                if quiet(*cmd, stdin=linear).returncode:
                    left.append("restore: " + " ".join(cmd))
        if mounted and quiet("umount", mnt).returncode:
            left.append("umount " + mnt)
        if created and quiet("dmsetup", "remove", "--retry", name).returncode:
            left.append("dm " + name)
        if loop and quiet("losetup", "-nO", "BACK-FILE", loop).stdout.strip() == img:
            if quiet("losetup", "-d", loop).returncode:
                left.append("loop " + loop)
        if left:
            say(f"  NOT torn down: {left}; {tmp} kept")
        else:
            shutil.rmtree(tmp)
        mark(f"{fstype} case ends")
        try:
            record_case(case_dir, kmsg.drain(), tables, mapping, facts)
        except Exception:
            say("  recording the case failed:\n" + traceback.format_exc())


def record_case(case_dir, recs, tables, mapping, facts):
    kept = [(ts, msg) for ts, msg in recs if not any(n in msg for n in NOISE)]
    lines = [f"[{ts:14.6f}] {msg}" if ts is not None else msg for ts, msg in kept]
    write(os.path.join(case_dir, "kmsg.txt"),
          "# Kernel records for this case, read from /dev/kmsg, kernel timestamps (s since\n"
          "# boot); 'fsyncretry:' lines are the script's step markers; UFW and AppArmor\n"
          f"# lines dropped ({len(recs) - len(kept)}).\n" + "\n".join(lines) + "\n")
    write(os.path.join(case_dir, "dm-tables.txt"), "\n".join(tables) + "\n")
    write(os.path.join(case_dir, "mapping.txt"), "\n".join(mapping) + "\n")
    write(os.path.join(case_dir, "fs.txt"), "\n".join(facts) + "\n")
    if not any("fsyncretry: " in msg and "case begins" in msg for _, msg in kept):
        say("  note: no step markers in the kernel log (kernel.printk_devkmsg?)")
    say("  kernel:")
    for line in lines:
        say("    " + line)


def provenance(owner_name, filesystems):
    head = git("rev-parse", "HEAD").stdout.strip()
    with open(SELF, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    with open("/proc/sys/kernel/random/boot_id") as f:
        boot_id = f.read().strip()
    lines = [
        f"recorded {datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')}",
        f"host {socket.gethostname()}",
        f"kernel {capture('uname', '-a')}",
        f"boot_id {boot_id}",
        f"owner {owner_name}",
        f"commit {head}",
        f"script_sha256 {digest}",
        f"python {sys.version.split()[0]}",
        f"filesystems {' '.join(filesystems)}",
        f"image {IMAGE_BYTES >> 20} MiB sparse under /var/tmp; loop --direct-io=on",
        f"file {FILE_BYTES >> 10} KiB of A, fsynced; test page at file offset {TEST_OFFSET}",
        "fault dm error target over the page's 8 sectors, armed for steps 1-2 and for step 5",
        f"printk_devkmsg {capture('cat', '/proc/sys/kernel/printk_devkmsg')}",
        "---- git status --short", git("status", "--short").stdout.rstrip(),
        "---- tools",
        capture("losetup", "--version"), capture("dmsetup", "--version"),
        (capture("mke2fs", "-V").splitlines() or [""])[0],
        capture("mkfs.xfs", "-V") if shutil.which("mkfs.xfs") else "mkfs.xfs not installed",
        "---- dm targets", capture("dmsetup", "targets"),
        "---- /var/tmp", capture("findmnt", "-no", "SOURCE,FSTYPE,OPTIONS", "-T", "/var/tmp"),
        "---- dm devices before the run", capture("dmsetup", "ls"),
        "---- vm.dirty_*",
    ]
    for f in sorted(os.listdir("/proc/sys/vm")):
        if f.startswith("dirty_"):
            with open(os.path.join("/proc/sys/vm", f)) as fh:
                lines.append(f"{f} {fh.read().strip()}")
    return "\n".join(lines) + "\n"


def summary(cases, head):
    labels = [label for label, _, _ in next(iter(cases.values()))]
    out = [f"# {REL} at {head}; kernel {os.uname().release}",
           "# per file system the result of each step, then its prediction; * = differs",
           f"{'step':<52} " + " ".join(f"{fs:<6}" for fs in cases) + " predicted"]
    for i, label in enumerate(labels):
        want = next(iter(cases.values()))[i][2]
        cells = []
        for fs, case_rows in cases.items():
            got = case_rows[i][1] if i < len(case_rows) else "-"
            cells.append(f"{got + ('*' if got != want else ''):<6}")
        out.append(f"{label:<52} " + " ".join(cells) + f" {want}")
    return "\n".join(out) + "\n"


def cmd_check(a):
    say(__doc__)
    missing = [t for t in TOOLS if not shutil.which(t)]
    say(f"tools: {'all present' if not missing else 'missing ' + ' '.join(missing)}; "
        f"mkfs.xfs {'present' if shutil.which('mkfs.xfs') else 'absent: XFS would be skipped'}")
    tracked = git("ls-files", "--error-unmatch", REL).returncode == 0
    clean = git("diff", "--quiet", "HEAD", "--", REL).returncode == 0
    say(f"script {'committed unchanged' if tracked and clean else 'not committed as it stands: run would refuse'}")
    say(f"==== dry run in {a.dir} (no fault)")
    d = tempfile.mkdtemp(prefix="fsyncretry-dry-", dir=a.dir)
    try:
        steps(os.path.join(d, "region"), lambda phys: None, lambda: None, False)
    finally:
        shutil.rmtree(d)
    differ = sum(got != want for _, got, want in rows)
    say(f"{differ} step(s) differ from the no-fault prediction")
    return 1 if differ else 0


def cmd_run(a):
    if not a.yes_inject_io_errors:
        raise SystemExit("run refused: requires --yes-inject-io-errors")
    if os.geteuid() != 0:
        raise SystemExit("run needs root via sudo (and --yes-inject-io-errors)")
    owner_name = os.environ.get("PWROOT_USER") or os.environ.get("SUDO_USER") or ""
    if not owner_name or owner_name == "root":
        raise SystemExit("set PWROOT_USER to the checkout's owner")
    pw = pwd.getpwnam(owner_name)
    if os.stat(REPO).st_uid != pw.pw_uid:
        raise SystemExit(f"{REPO} is not owned by {owner_name}")
    Out.owner = (pw.pw_uid, pw.pw_gid)
    missing = [t for t in TOOLS if not shutil.which(t)]
    if missing:
        raise SystemExit(f"missing tools: {' '.join(missing)}")
    targets = run("dmsetup", "targets").split()
    if "error" not in targets or "linear" not in targets:
        raise SystemExit("the dm error or linear target is unavailable")
    filesystems = a.fs or ["ext4"] + (["xfs"] if shutil.which("mkfs.xfs") else [])
    for fs in filesystems:
        if fs not in ("ext4", "xfs"):
            raise SystemExit(f"unknown file system {fs}")
        if fs == "xfs" and not shutil.which("mkfs.xfs"):
            raise SystemExit("xfs requested but mkfs.xfs is not installed")
    if git("ls-files", "--error-unmatch", REL).returncode != 0 or \
            git("diff", "--quiet", "HEAD", "--", REL).returncode != 0:
        raise SystemExit(f"commit {REL} first, so the recorded commit describes it")
    head = git("rev-parse", "HEAD").stdout.strip()

    os.umask(0o077)
    host = socket.gethostname().split(".")[0]
    tag = "sean-tan-PC" if host == "pc-ubuntu" else host
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = tempfile.mkdtemp(prefix=f"{stamp}-{tag}-fsyncretry-", dir=os.path.join(REPO, "results"))
    own(out_dir)
    Out.log = open(os.path.join(out_dir, "run.log"), "w")
    own(os.path.join(out_dir, "run.log"))
    Out.markers = True
    copy = os.path.join(out_dir, os.path.basename(SELF))
    shutil.copy2(SELF, copy)
    own(copy)
    write(os.path.join(out_dir, "provenance.txt"), provenance(owner_name, filesystems))
    say(f"kernel {os.uname().release}, python {sys.version.split()[0]}, commit {head}")
    cases = {}
    status = 0
    try:
        for fs in filesystems:
            rows.clear()
            try:
                real_case(fs, out_dir)
            finally:
                cases[fs] = list(rows)
    except SystemExit as e:
        say(f"error: {e}")
        status = 2
    except Exception:
        say("error:\n" + traceback.format_exc())
        status = 2
    if cases and all(cases.values()):
        write(os.path.join(out_dir, "summary.txt"), summary(cases, head))
    differ = sum(got != want for case_rows in cases.values() for _, got, want in case_rows)
    say(f"{differ} step(s) differ from the prediction")
    say(f"results: {os.path.relpath(out_dir, REPO)}")
    Out.log.close()
    Out.log = None
    return status or (1 if differ else 0)


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(129))
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="no root, no fault: the plan, the tools, a dry run")
    c.add_argument("--dir", default=os.path.expanduser("~"),
                   help="where the dry run makes its file (default: home)")
    r = sub.add_parser("run", help="root: inject the fault, write results/")
    r.add_argument("--yes-inject-io-errors", action="store_true")
    r.add_argument("fs", nargs="*", help="ext4, xfs (default: both, xfs if installed)")
    a = p.parse_args()
    try:
        return cmd_check(a) if a.cmd == "check" else cmd_run(a)
    except SystemExit as e:
        # A refusal or a stop, with its reason; signals keep their own codes.
        if isinstance(e.code, str):
            print(f"error: {e.code}", file=sys.stderr)
            return 2
        raise


if __name__ == "__main__":
    sys.exit(main())
