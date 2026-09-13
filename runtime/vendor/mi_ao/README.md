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

**`MI_AO_SendFrame`'s two words.** its 8-byte payload is built at `r7+0x60` from a value computed
earlier in a 216-byte stack frame; the second word is copied from `r7+0xa8`. that it is `{dev, chn}`
is an inference from the size and from the `MI_SYS_Mmap` dependency, not something traced through.

**the field layouts inside `MI_AUDIO_Attr_t` and the `MI_SYS` payloads.** sizes are exact,
fields are not.

## about the codecs

there is **no hardware mp3 decode on this device**, so do not plan around one. the vendor's own
player decodes in software: `libzkmedia.so` has an `Mp3AudioParser` calling `mad_frame_decode`, and
`/lib/libmad.so.0.2.1` (83 kb) ships on the device to provide it. beneath that sits
`SoundDevice::init(rate, channels)` / `output(buf, len)` / `setVolume(float)`, which is exactly the
shape above. `mi_ao` takes pcm and only pcm; its debug dump format is `.pcm`; no codec name appears
anywhere in `libmi_ao.so`; and the `mi_adec` kernel module is not even loaded (only `mi_ao` is).

the `MI_AO_EnableAdec` / `MI_AO_SetAdecAttr` entry points exist, but the vendor does not use them
for mp3 — which is the strongest evidence available that they would not help.
