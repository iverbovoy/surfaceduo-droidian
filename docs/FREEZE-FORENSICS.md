# Freeze forensics: evidence for patches 0004 and 0005

Environment for every measurement below: Surface Duo 1, kernel
msm-4.14.190 (branch `surfaceduo/11/2022.902.48`) built per
`kernel-packaging/`, Droidian nightly api30 arm64 (101.20251130,
Debian 13), rootfs.img (8 GB, ext4) loop-mounted from an ext4 userdata
(`/dev/sda6`), adaptation 0.9.x. Dates: 2026-07-11..12.

## The symptom

Minutes to hours into uptime the phone "freezes": ICMP still answers,
resident processes keep logging, but anything that touches the disk
(spawning an ssh session, launching an app) hangs indefinitely. Screens
stay dark. Only a forced reboot recovers.

## Raw signals, before the fixes

Write bios failing on the loop-backed root, in bursts (all sectors map
to one file - see below):

```
[   33.667763] print_req_error: I/O error, dev loop1, sector 10422736
[   33.677454] print_req_error: I/O error, dev loop1, sector 10422752
```

Interleaved with a message that exists in no mainline kernel:

```
EXT4-fs (loop1): errors=remount-ro for active namespaces on umount 2
```

The mount state of the era (note `data=journal,nodelalloc` on the
OUTER filesystem, forced by the halium initramfs):

```
/dev/sda6  /userdata      ext4 rw,relatime,discard,nodelalloc,data=journal
/dev/loop1 /              ext4 rw,relatime,errors=remount-ro,data=ordered
```

Mapping the failing sectors through debugfs (sector/8 = fs block):

```
# debugfs -R "icheck 1247545" /dev/loop1   -> inode 262482
# debugfs -R "ncheck 262482" /dev/loop1
262482  /var/log/journal/<machine-id>/system.journal
```

Every failing block belonged to journald's active journal file, which
matches journald's own per-boot complaint:

```
File .../system.journal corrupted or uncleanly shut down, renaming and replacing.
```

## Finding 1 (patch 0004): the Android ext4 `umount_end` hook

`fs/namespace.c` in msm-4.14 calls an Android-only super_operations
hook at the end of every **user** umount(2):

```c
if (user_request && (!retval || (flags & MNT_FORCE))) {
        /* filesystem needs to handle unclosed namespaces */
        if (mnt->mnt.mnt_sb->s_op->umount_end)
                mnt->mnt.mnt_sb->s_op->umount_end(mnt->mnt.mnt_sb, flags);
}
```

ext4's implementation, when the superblock is still active elsewhere
(`s_active > 1` - always true for the root, which lives in every
service's mount namespace):

```c
clear_opt(sb, ERRORS_PANIC);
set_opt(sb, ERRORS_RO);                    /* silently change policy   */
if (!(sb->s_flags & MS_RDONLY))
        ext4_commit_super(sb, 1);          /* sync write to a LIVE fs  */
```

systemd tears down mount namespaces with `umount2(..., MNT_DETACH)`
("umount 2" in the log line) constantly - every sandboxed service
lifecycle. Each teardown = one synchronous superblock commit racing
the journal, plus one step towards errors=remount-ro on the root.

Measured consequences, same device, same day:

| Metric | with hook | hook removed (0004) |
|---|---|---|
| Sandboxed unit spawn (`systemd-run -p ProtectSystem=strict ... /bin/true`) | ~40 s | **0.18 s** |
| "active namespaces on umount" per boot | 25-48 | 0 |
| Root reaches read-only under error accumulation | yes ("freeze") | no |

The 40 s spawn stall had earlier been misattributed to RCU
(`__wait_rcu_gp` was where the umounts waited); the actual cost was
the synchronous superblock write per umount.

An important honesty note: the failing journald writes existed on
"good" days too - the golden 12.5-hour uptime the day before showed
58 print_req_error lines and 31 hook firings, unnoticed. The hook is
not the *source* of the write errors; it is the escalation mechanism
that turned a contained nuisance into a dead phone.

## Finding 2 (patch 0005): `data=journal` on the outer filesystem

The halium initramfs (`scripts/halium`), 2014 vintage:

```sh
# FIXME: data=journal used on ext4 as a workaround for bug 1387214
[ `blkid $path -o value -s TYPE` = "ext4" ] && OPTIONS="data=journal,"
```

With the rootfs being a loop image ON that partition, every root write
is journaled twice (inner fs journal, then ALL data through the outer
journal). Under a write burst jbd2 starves and loop bios start
failing; a plain `dpkg -i` of a 20 MB package produced a multi-minute
I/O stall (kernel with 0004 only, i.e. escalation already off).

After switching to `data=ordered` (patch 0005), same device:

```
# dd if=/dev/urandom of=/var/tmp/burst-test bs=1M count=300 conv=fsync
314572800 bytes (315 MB, 300 MiB) copied, 6.07933 s, 51.7 MB/s
errors after dpkg + 300MB fsync burst: delta 0
```

Trade-off: lp#1387214 was about data loss on dirty power-offs of
2014-era eMMC devices. `data=ordered` keeps metadata consistency but
can lose recently written file content on a sudden power cut.

## What is fixed and what is not

- Fixed: read-only-root "freezes" (0004), 40 s sandboxed-service
  spawns (0004), multi-minute I/O stalls under write bursts (0005).
- Not fixed (known wart): ~8-9 `print_req_error` lines still appear
  ~33 s into every boot, all targeting journald's freshly flushed
  journal file. journald rotates and recovers by itself; root cause
  still unidentified. Contributions welcome.
