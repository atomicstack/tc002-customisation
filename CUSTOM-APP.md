# Ulanzi TC002 — Custom App payload

The frame format the device accepts for "custom apps" (the stock UI calls them
DIY apps), shared by the local HTTP endpoint and the MQTT topic. Part of
[tc002-customisation](README.md); the transports are described in
[HTTP-API.md](HTTP-API.md#custom-apps) and [MQTT.md](MQTT.md).

Everything here comes from what [PixDeck](https://github.com/cailurus/PixDeck)
sends to stock firmware and observes working — it drives the display through
this protocol only, over either transport, with no flashing. Where PixDeck has
not exercised something it is marked *not established*.

---

## Transports

| Transport | Where the payload goes | Notes |
|-----------|------------------------|-------|
| HTTP | `POST /api/custom?name=<app>` with `Content-Type: application/json` | no broker needed; the device answers immediately |
| MQTT | `PUBLISH <prefix>/custom/<app>` (QoS 0 is enough) | `<prefix>` is `mqtt_prefix` from `GET /getMqttConfig` |

The JSON body is identical on both. `<app>` is a short ASCII name of your
choosing; the first push to a new name creates the app, later pushes to the
same name replace its content.

## Lifecycle

- A custom app appears in `GET /api/customList` (`{"apps": ["snake", …],
  "count": 1}`) and in the device's own UI as a DIY app as soon as the first
  frame is pushed.
- It stays on the device after the frame's `duration` runs out and after the
  sender goes away. To remove it, post an **empty object** `{}` to the same
  name over HTTP — PixDeck does this whenever a plugin stops and at startup for
  apps it left behind, and it reliably removes the entry. Whether `{}` also
  removes the app when published over MQTT is *not established*.
- Whether custom apps survive a device reboot is *not established*.
- Keeping content live is the sender's job: PixDeck re-pushes a frame every
  `duration` seconds (or faster for animation), so the display never goes
  stale. Full-screen bitmap frames at roughly 8 per second over HTTP work
  fine.

## Payload

```json
{
  "duration": 5,
  "text":  [ { "content": "HELLO", "fontHeight": 10, "x": -1000, "y": 3,
               "align": "center", "rect": [0, 0, 52, 16], "color": "#3EE08A" } ],
  "draw":  [ { "df": [2, 5, 1, 6, "#00FF66"] },
             { "dl": [10, 8, 40, 8, "#2A3038"] } ],
  "image": [ { "data": "data:image/gif;base64,R0lGOD…", "position": [0, 0] } ]
}
```

All three arrays are optional and may be combined in one frame (PixDeck's
plugins mix `text` with `draw` routinely). The display is 52 columns × 16
rows; `x` grows to the right and `y` downwards from the top-left pixel.

### `duration`

Seconds. Observed use: the time the frame stays up. PixDeck sets it to its
own push interval and keeps re-pushing, so in practice it never expires; the
exact interaction with the device's app carousel is *not established*.
PixDeck's canvas tool clamps it to 1–300 as a sanity bound of its own, not a
device limit.

### `text[]`

| field | meaning |
|-------|---------|
| `content` | the string to render — **ASCII only**, see the font note below |
| `fontHeight` | `10` is the size PixDeck uses everywhere and renders well; a 10 px glyph is about 6 px wide (PixDeck's estimate for scrolling). Other values *not established* on the device |
| `x`, `y` | top-left of the text. `y: 3` vertically centres a 10 px line on the 16-row panel |
| `color` | `"#RRGGBB"` string |
| `align` | `"center"` or `"right"`, positioning the text inside `rect`. PixDeck pairs it with `x: -1000` so the horizontal position comes from `align`, not `x` |
| `rect` | `[x, y, w, h]` — the box the text is aligned within; PixDeck also uses it as a clip region for scrolling text (`rect: [10, 0, 42, 16]` next to an icon) |

**The device does not scroll text.** Long strings are simply clipped. PixDeck
implements the marquee itself: re-push the frame every 0.4–0.5 s with `x`
decreased by 5 px, wrapping when the text has left the box.

**Font.** Only printable ASCII (`0x20`–`0x7E`) renders, and the lowercase
range has missing glyphs (a lowercase `t` comes out blank). PixDeck therefore
NFKD-transliterates accents (`café` → `cafe`), drops anything non-ASCII, and
upper-cases everything before sending. PixDeck never sends an empty `content`
(it substitutes a single space); the device's handling of `""` is *not
established*.

### `draw[]`

Each entry is a one-key object naming a primitive. Colours are `"#RRGGBB"`
strings except inside `db`, where pixels are integers.

| op | arguments | draws |
|----|-----------|-------|
| `dp` | `[x, y, color]` | one pixel |
| `dl` | `[x1, y1, x2, y2, color]` | a line (PixDeck draws horizontal, vertical and diagonal segments with it) |
| `dr` | `[x, y, w, h, color]` | a rectangle outline |
| `df` | `[x, y, w, h, color]` | a filled rectangle |
| `db` | `[x, y, w, h, pixels]` | a bitmap: `pixels` is a flat, row-major array of `w × h` integers, each `0x00RRGGBB` written in decimal (`65280` is green) |

A full-screen `db` is `[0, 0, 52, 16, <832 ints>]`, about 5 KB of JSON, and is
how PixDeck renders all of its games and particle effects — one `db` per frame
instead of hundreds of `dp`s.

### `image[]`

`{ "data": "<data URI>", "position": [x, y] }`. Animated GIFs work, and they
are not limited to 8×8 icons: PixDeck's pixel-pet plugin pushes full-frame
52×16 animated GIFs as `data:image/gif;base64,…` at `position: [0, 0]` and the
device plays the animation. The `/icons/` directory mentioned in Ulanzi's
community apps is a second way to reference images and is *not established*
here.

## Examples

```bash
# a centred line of text for ten seconds
curl -s -X POST 'http://<device-ip>/api/custom?name=hello' \
  -H 'Content-Type: application/json' \
  -d '{"duration":10,"text":[{"content":"HELLO","fontHeight":10,"x":-1000,"y":3,
       "align":"center","rect":[0,0,52,16],"color":"#3EE08A"}]}'

# a bar chart: outline plus a fill that grows with the value
curl -s -X POST 'http://<device-ip>/api/custom?name=cpu' \
  -H 'Content-Type: application/json' \
  -d '{"duration":5,"text":[{"content":"CPU","fontHeight":10,"x":2,"y":3,"color":"#FFFFFF"}],
       "draw":[{"dr":[30,2,20,12,"#3EE08A"]},{"df":[30,8,20,6,"#3EE08A"]}]}'

# what is on the device
curl -s http://<device-ip>/api/customList | jq .

# remove one
curl -s -X POST 'http://<device-ip>/api/custom?name=hello' \
  -H 'Content-Type: application/json' -d '{}'
```

Over MQTT, publish the same body to `<prefix>/custom/hello`:

```bash
mosquitto_pub -h <broker> -t 'ulanzi_1bf6/custom/hello' \
  -m '{"duration":10,"text":[{"content":"HELLO","fontHeight":10,"x":-1000,"y":3,"align":"center","rect":[0,0,52,16],"color":"#3EE08A"}]}'
```

## Reference implementation

PixDeck's `pixbar_core.py` holds the smallest useful pieces: `push()` (the
HTTP POST / MQTT publish switch), `text_frame()` (centre-if-it-fits text),
`bitmap_frame()` (full-screen `db`) and `ascii_upper()` (the font workaround).
Its `plugins/` directory is a catalogue of working frames — `sysmon` for
`dr`/`df`/`dl`/`dp`, `snake` and `weather` for `db`, `nowplaying` and `notice`
for the marquee, `pet` for animated GIFs.
