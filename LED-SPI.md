# the led panel over raw spi

the 52×16 led matrix is not a framebuffer device. the stock app (`zkgui`, init
service `zkswe`) renders each frame in software and ships it to the panel's mcu
over spi with a gpio latch. anything that can open two device nodes can do the
same, which is how [`led/popsquares`](led/) runs generative art at a locked
60 fps on the device itself, with no wifi and no json in the loop. the
custom-app route over http/mqtt (`CUSTOM-APP.md`) tops out
around 30 fps because the app parses and renders every frame.

## how the panel is driven

| item | value |
|------|-------|
| bus | `/dev/spidev0.0`, spi mode 0, 8 bits per word, 10 000 000 hz |
| latch | `GPIO_35`, exported at `/sys/class/gpio/gpio35`, idles high |
| frame | 3072 bytes = 16 rows × 192 bytes; a row is 52 pixels × 3 bytes (r, g, b) followed by 36 zero bytes |
| per frame | gpio35 ← 0, wait 1 ms, `write()` the 3072 bytes, wait 1 ms, gpio35 ← 1 |
| level curve | the app maps every byte before sending: 0 → 0, otherwise `50 + (v−1)·205/254` (so 1 → 50 and 255 → 255): the driver has a floor of 50 |
| brightness | applied before the curve: `byte × brightness / 100` |
| rate | the stock app allows one frame per 15 ms at most (~66 fps); the bus itself needs ~2.5 ms per frame |

established on a live device (2026-09-03):

- **the pulse is required.** a plain write to spidev never changes the panel.
  the falling edge on gpio35 appears to reset the mcu's receive pointer and the
  rising edge latches the frame.
- **one frame of lag.** the panel shows a frame when the *next* pulsed frame
  arrives (double-buffered in the mcu). to leave an image, or black, on exit,
  write it twice.
- pixel byte order is r, g, b; rows run top to bottom, pixels left to right.
- the display holds the last frame when nothing is sending. the mcu has no
  clock mode of its own.
- `/dev/fb0` (640×480, 32 bpp, "spilcd") is unrelated to the leds: it scans out
  a flat gray buffer nobody looks at.
- the mcu serial link (`/dev/ttyS1`: gain, mic, battery, power commands) is not
  needed for pixels.

source: the frame callback in `/res/lib/libzkgui.so`, an awtrix port
(`SpiHelper(0, 0, 10000000, 8)`, `GpioHelper::output("GPIO_35", …)`),
cross-checked by writing known frames from the device shell.

## taking over the panel

only one process can usefully own spidev0.0, so the stock app is stopped first.
it is an init service:

```
setprop ctl.stop zkswe     # http api and clock go away; the last frame stays on the panel
… drive spidev0.0 + gpio35 …
setprop ctl.start zkswe    # clock and api are back within ~3 s
```

nothing persists: no kernel changes, no files outside `/tmp`. a reboot always
comes up stock. from the device shell (mksh, no `sleep`) a single frame can be
shown with:

```
echo 0 > /sys/class/gpio/gpio35/value; cat frame.bin > /dev/spidev0.0; echo 1 > /sys/class/gpio/gpio35/value
```

## `led/`: native popsquares at 60 fps

[`led/`](led/) is a small c program that runs the popsquares animation (the
same one as the pixdeck plugin, itself a port of a processing sketch) directly
on the device:

| file | role |
|------|------|
| `led.h`, `led_frame.c`, `led_dev.c` | the reusable part: frame packing with the brightness and level curve above, and the spidev + gpio writer |
| `popsquares.h`, `popsquares.c` | the simulation: pure, seedable, advances by wall-clock time |
| `main.c` | options, deadline-based frame loop, clean exit (black frame twice, latch released) |
| `tc002-led.sh` | host wrapper over adb: start / stop / status |
| `test_*.c`, `check.h`, `Makefile` | host unit tests and the cross build |

build needs only [zig](https://ziglang.org) (`brew install zig`); it bundles
clang, musl and the linux headers, so there is no separate cross toolchain:

```bash
cd led
make test     # host unit tests
make          # ./popsquares — static armv7 binary, ~40 kb
```

run (after `adb connect <device-ip>`, see `DEVICE.md`):

```bash
./tc002-led.sh start --stats     # stop zkswe, push to /tmp, run detached
./tc002-led.sh status            # pid plus the fps log
./tc002-led.sh stop              # sigterm → black frame → zkswe restarted
```

options, defaults in brackets: `--fps [60] --pop [2] --alive [100] --dim [25]
--dim-min [0] --dim-max [127] --tint-pct [15] --tint [3a6ea5] --brightness [100]
--seconds [run until stopped] --seed [from the clock] --dry-run --stats`.
`--dry-run` runs the loop without touching the hardware, so it is safe with
`zkswe` running and is a quick check that the cpu keeps up.

measured on the device: 60.0 fps sustained with real spi writes, no short or
failed writes, the stock app back within 3 s of `stop`.

limits: the binary lives in the device's tmpfs and there is no autostart hook
without reflashing, so a reboot returns the device to stock; run `start` again.
while it runs the http api is down (`zkswe` is stopped). brightness is a cli
option rather than read from the device's settings.
