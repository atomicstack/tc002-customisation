# the sigmastar audio-out interface, as recovered

no vendor code is copied here. this is the **ioctl abi of `/dev/mi_ao`**, read out of the device's
own `/lib/libmi_ao.so` (36,704 bytes, `sdk_commit.74b913c`, built 2021-05-27) so the runtime can
drive the speaker the way it already drives the led panel: a device node and raw ioctls, static, no
libc.

everything below is measured from the unit, not from an sdk header. reproduce it with:

```bash
adb pull /lib/libmi_ao.so
objdump -d --triple=thumbv7-unknown-linux-gnueabihf libmi_ao.so   # it is thumb-2, not arm
```

## why not just link the vendor library

`libmi_ao.so` is dynamically linked against **glibc** (`libc.so.6`; the device carries glibc 2.30 and
`ld-linux-armhf.so.3`). our binaries are static with no dynamic loader, so a static musl process
could not load it either — using it would mean a dynamically linked, glibc-targeting binary, the
first in this runtime.

it turns out not to be worth it. the library needs exactly four things from libc — `open`, `ioctl`,
`memcpy`, `__errno_location` — because it is a thin shim over the node. reimplementing the shim is
less work than taking on a dynamic dependency, and `sys/linux.zig` already has `ioctl`.

## the call shape

every entry point is the same: build a small struct on the stack, wrap it in a 16-byte envelope,
and issue one ioctl on an fd for `/dev/mi_ao`.

```
envelope (16 bytes)            inner struct
+0  u32  size of inner         the per-call payload below
+4  u32  (zero)
+8  u64  pointer to inner      sign-extended from the 32-bit address
```

```c
ioctl(fd, request, &envelope);
```

`request` is `_IOW('i', nr, sizeof inner)` — magic `'i'` (0x69) throughout, `_IOWR` where the call
reads something back.

## the numbers

| nr | call | request | dir | inner |
|---:|------|---------|-----|------:|
| 0 | `MI_AO_SetPubAttr` | `0x40386900` | `_IOW` | 56 b |
| 1 | `MI_AO_GetPubAttr` | `0xc0386901` | `_IOWR` | 56 b |
| 2 | `MI_AO_Enable` | `0x40046902` | `_IOW` | 4 b |
| 3 | `MI_AO_Disable` | `0x40046903` | `_IOW` | 4 b |
| 4 | `MI_AO_EnableChn` | `0x40086904` | `_IOW` | 8 b |
| 5 | `MI_AO_DisableChn` | `0x40086905` | `_IOW` | 8 b |
| 6 | `MI_AO_SendFrame` | `0x40086906` | `_IOW` | 8 b |
| 7 | `MI_AO_PauseChn` | `0x40046907` | `_IOW` | 4 b |
| 8 | `MI_AO_ResumeChn` | `0x40046908` | `_IOW` | 4 b |
| 9 | `MI_AO_ClearChnBuf` | `0x40086909` | `_IOW` | 8 b |
| 10 | `MI_AO_QueryChnStat` | `0xc014690a` | `_IOWR` | 20 b |
| 11 | `MI_AO_SetVolume` | `0x4010690b` | `_IOW` | 16 b |
| 12 | `MI_AO_GetVolume` | `0xc00c690c` | `_IOWR` | 12 b |
| 13 | `MI_AO_SetMute` | `0x400c690d` | `_IOW` | 12 b |
| 14 | `MI_AO_GetMute` | `0xc00c690e` | `_IOWR` | 12 b |
| 15 | `MI_AO_ClrPubAttr` | `0x4004690f` | `_IOW` | 4 b |
| 22 | `MI_AO_SetChnParam` | `0x40146916` | `_IOW` | 20 b |
| 23 | `MI_AO_GetChnParam` | `0xc0146917` | `_IOWR` | 20 b |
| 24 | `MI_AO_SetSrcGain` | `0x40086918` | `_IOW` | 8 b |

19 of the 36 exported `MI_AO_*` symbols. the rest are the vqe, resample, adec, queue and pcm-dump
helpers; several of those never reach the driver at all.

**`MI_AO_SetMute` (nr 13) is the one to call first when testing on a device somebody lives with.**

## what is not recovered yet

**the data plane.** `MI_AO_SendFrame`'s payload is only 8 bytes — room for `{dev, chn}` and nothing
else — because the pcm does not travel through the ioctl. the library references `MI_SYS_Mmap` and
`MI_SYS_Munmap`, so the samples go through an mi_sys shared buffer and the ioctl only says which
device and channel to drain. finishing playback therefore needs the equivalent recovery for
`/lib/libmi_sys.so` and `/dev/mi_sys` (also `crw-------`, root only).

**the struct fields.** the sizes above are exact; the field layouts are not yet decoded. the
56-byte `SetPubAttr` payload is the one that matters — it carries sample rate, channel count and
bit depth, and getting it wrong is how a test turns into a noise rather than into silence.

## about the codecs

there is **no hardware mp3 decode on this device**, so do not plan around one. the vendor's own
player decodes in software: `libzkmedia.so` has an `Mp3AudioParser` calling `mad_frame_decode`, and
`/lib/libmad.so.0.2.1` (83 kb) ships on the device to provide it. beneath that sits
`SoundDevice::init(rate, channels)` / `output(buf, len)` / `setVolume(float)`, which is exactly the
shape above. `mi_ao` takes pcm and only pcm; its debug dump format is `.pcm`; no codec name appears
anywhere in `libmi_ao.so`; and the `mi_adec` kernel module is not even loaded (only `mi_ao` is).

the `MI_AO_EnableAdec` / `MI_AO_SetAdecAttr` entry points exist, but the vendor does not use them
for mp3 — which is the strongest evidence available that they would not help.
