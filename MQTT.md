# Ulanzi TC002 — MQTT

Pushing text and images to the 52×16 display over a broker you control.

MQTT is one of two ways to drive the display without Ulanzi Studio; the other
is `POST /api/custom` over plain HTTP, which takes the identical payload and
needs no broker (see [HTTP-API.md](HTTP-API.md#custom-apps)). Use MQTT when
the sender should not need the device's IP, or when several senders share
one device.

Configure a broker via `/setMqttConfig` or the `/settings/mqtt` page (see
`HTTP-API.md`). Home Assistant discovery is available
(`isHADiscoveryEnabled`).

**Custom App topic:** `[PREFIX]/custom/[APP_NAME]` — e.g.
`ulanzi_1bf6/custom/vibe_signal`. Default prefix is `ulanzi`.

**Payload:**

```json
{
  "duration": 10,
  "text": [],
  "image": [{ "data": "data:image/gif;base64,<...>", "position": [0, 0] }],
  "draw": []
}
```

The display is **52x16 RGB**. Icons are 8x8 PNG/GIF, either inlined as data
URIs or pre-loaded into the device's `/icons/` directory. The full field
reference — `text` fields and the ASCII-only font, the `draw` primitives
(`dp`/`dl`/`dr`/`df`/`db`), full-frame animated GIFs in `image`, and the
create/replace/remove lifecycle — is in `CUSTOM-APP.md`.

**Client requirements**, as established by [PixDeck](https://github.com/cailurus/PixDeck)'s
stdlib MQTT publisher (`pixbar_mqtt.py`), which drives the device in production:

- MQTT 3.1.1 (protocol level 4), clean session, any client id.
- `PUBLISH` at QoS 0 is sufficient; `retain` is optional. Whether the device
  processes a retained frame on reconnect is not established.
- A keepalive of 0 (no pings) is accepted by mosquitto and works; PixDeck simply
  reconnects on the next publish if the socket has dropped.
- Username/password are optional and sent in the `CONNECT` when configured.
- The topic prefix must match `mqtt_prefix` from `GET /getMqttConfig`; the
  device only reacts to `<prefix>/custom/<app>`.
- Publishing `{}` to remove an app works over HTTP; over MQTT it is not
  established.

Besides `custom/<app>`, the device subscribes to **`<prefix>/switchDiyApp`** —
publishing a custom app's name there brings it to the foreground, the broker
equivalent of `POST /api/switchDiyApp` (see
[HTTP-API.md](HTTP-API.md#navigation-and-input)). The built-in apps and the
button/knob injection are HTTP-only.

Ulanzi's repo ships community MQTT apps under `apps/mqtt/`, including
`vibe-coding-signal-light` (shows Claude Code / Codex / CI state as a traffic
light) and `claude-bot`. These achieve the same result as Ulanzi Studio's
agent-hook integration, but over a broker you control.

Before pointing the device at a broker, `mqtt-check.py` (see the
[README](README.md#quick-start)) verifies the credentials from the raw MQTT
CONNACK code.
