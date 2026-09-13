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

## payload layouts

measured by reading how the library fills each payload, not taken from a header.

**`MI_AO_SetPubAttr` (56 b)** — the one that decides the sample format:

```
memset(inner, 0, 56)
inner[+0]  = AoDevId            (u32)
memcpy(inner+4, pstPubAttr, 52) (the caller's MI_AUDIO_Attr_t, verbatim)
```

so the attribute struct is **52 bytes copied straight through**. its *fields* are
not decoded — only its size. the published mstar/sigmastar shape for
`MI_AUDIO_Attr_t` (sample rate, bit width, work mode, sound mode, then frame and
point counts, then an i2s config block) fits 52 bytes, but that is a hypothesis
to check against the device, not a measurement. **it is the thing to verify first
and the thing most likely to turn a silent test into a loud one.**

### the attribute payload, decoded

the 52 bytes are no longer a guess. `libzkmedia.so` — the vendor's own media layer, which is **arm
rather than thumb-2**, unlike `libmi_ao.so` — has `media::SoundDevice::init(channels, rate)`, and it
builds the payload in the open:

```
memset(attr, 0, 52)
attr[+0]  = rate            (44100 etc., the plain integer)
attr[+12] = 1 if channels == 2 else 0      (sound mode: stereo/mono)
attr[+16] = 4
attr[+20] = 1024
attr[+28] = 1
everything else zero
MI_AO_SetPubAttr(0, attr)
```

the argument order is confirmed by the log line immediately above it, whose varargs are `r3` and
`[sp]`: `"sound channels: %d, rate: %d"`. so the first parameter is the channel count and the second
is the rate, and the rate is what lands at offset 0.

this is the vendor's own configuration, copied rather than interpreted. the field *names* still are
not known — `+16 = 4` and `+20 = 1024` are frame and point counts in the published mstar layout, in
some order — but the bytes are what the device is known to accept, which is the part that matters.

### the frame, and how pcm is handed over

`media::SoundDevice::output(buf, len)` is equally plain:

```
memset(frame, 0, 288)
frame[+8]  = the pcm pointer
frame[+84] = the byte count
do { r = MI_AO_SendFrame(dev=0, chn=0, &frame, timeout=-1) } while (r == 0xA005200D)
```

so `MI_AUDIO_Frame_t` is **288 bytes** with the buffer at +8 and the length at +84, and
**`0xA005200D` means the device's buffer is full** — the vendor spins on it rather than treating it
as an error.

### verified on the device, 2026-09-13

`zig build soundprobe` builds `tc002-soundprobe`, which walks the control plane and prints what each
ioctl returned. on the unit, at 44,100 hz mono, **every one succeeded**:

```
MI_SYS_Init: ok      MI_AO_SetPubAttr: ok   MI_AO_Enable: ok     MI_AO_EnableChn: ok
MI_AO_SetMute: ok    MI_AO_QueryChnStat: ok MI_AO_DisableChn: ok MI_AO_Disable: ok
```

so the envelope, the request numbers and the 52-byte attribute payload are **confirmed correct on
hardware**, not merely recovered. the renderer kept presenting throughout and the device was
unaffected.

`MI_AO_SendFrame` was then tried with candidate payloads, with silence in the buffer. `{dev=0,
chn=0}` and `{0, &frame}` both returned success — which proves nothing on its own, because an ioctl
returning 0 does not mean samples were queued, and `QueryChnStat` stayed all zeros. a third variant
(`{&frame, 0}`) segfaulted the probe process; the device itself was untouched.

**what is still not recovered** is the last hop: how `MI_AO_SendFrame` turns that 288-byte frame into
the 8-byte `{?, ?}` payload its ioctl carries. it does copy: there is a loop inside it
reading 16-bit samples from the caller's buffer and writing them, strided, into a destination the
function obtained earlier. the vendor's *player* never allocates that destination — `libzkmedia.so`
calls neither `MI_SYS_MMA_Alloc` nor `MI_SYS_Mmap` — so the buffer is obtained inside
`MI_AO_SendFrame` itself, lazily, which is why the library references those two calls at all.

replicating it therefore needs three more things: the 48-byte `MI_SYS_MMA_Alloc` payload, the
24-byte `MI_SYS_Mmap` payload, and `mmap` in `sys/linux.zig`, which does not have it. **that is what
stands between this runtime and a sound**, and it is a larger piece of work than the control plane
was.

**`MI_SYS_*` payloads** follow the same envelope. the calls the audio path needs:

| call | nr | request | inner |
|---|---:|---|---:|
| `MI_SYS_Init` | 0 | `0x80046900` | 4 b |
| `MI_SYS_Mmap` | 10 | `0xc018690a` | 24 b |
| `MI_SYS_Munmap` | 11 | `0x4008690b` | 8 b |
| `MI_SYS_MMA_Alloc` | 27 | `0xc030691b` | 48 b |
| `MI_SYS_MMA_Free` | 28 | `0x4008691c` | 8 b |
| `MI_SYS_FlushInvCache` | 29 | `0x4008691d` | 8 b |

all 49 exported `MI_SYS_*` calls decode with the same technique and the same
magic `'i'`; the six above are the ones playback uses.

## the playback path, as it now looks

1. `MI_SYS_MMA_Alloc` — a physically contiguous buffer for the samples
2. `MI_SYS_Mmap` — map it into this process
3. write pcm into it
4. `MI_SYS_FlushInvCache` — make it visible to the dma engine
5. `MI_AO_SetPubAttr` / `Enable` / `EnableChn` — configure and open the device
6. `MI_AO_SendFrame` — whose payload is only `{dev, chn}`, because the samples are
   already in the shared buffer

## what is not recovered yet

**`MI_AO_SendFrame`'s two words**, as described above — the one remaining blocker.

**the `MI_SYS` payload layouts.** sizes are exact, fields are not. they may not be needed at all:
the vendor hands `SendFrame` an ordinary pointer to its own stack, so the shared-buffer path may
belong to a different caller entirely.

## about the codecs

there is **no hardware mp3 decode on this device**, so do not plan around one. the vendor's own
player decodes in software: `libzkmedia.so` has an `Mp3AudioParser` calling `mad_frame_decode`, and
`/lib/libmad.so.0.2.1` (83 kb) ships on the device to provide it. beneath that sits
`SoundDevice::init(rate, channels)` / `output(buf, len)` / `setVolume(float)`, which is exactly the
shape above. `mi_ao` takes pcm and only pcm; its debug dump format is `.pcm`; no codec name appears
anywhere in `libmi_ao.so`; and the `mi_adec` kernel module is not even loaded (only `mi_ao` is).

the `MI_AO_EnableAdec` / `MI_AO_SetAdecAttr` entry points exist, but the vendor does not use them
for mp3 — which is the strongest evidence available that they would not help.
