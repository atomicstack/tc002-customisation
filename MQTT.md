# Ulanzi TC002 — MQTT

Pushing text and images to the 52×16 display over a broker you control. Part
of [tc002-customisation](README.md).

MQTT is the supported way to drive the display without Ulanzi Studio.
Configure a broker via `/setMqttConfig` or the `/settings/mqtt` page (see
[HTTP-API.md](HTTP-API.md)). Home Assistant discovery is available
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
URIs or pre-loaded into the device's `/icons/` directory.

Ulanzi's repo ships community MQTT apps under `apps/mqtt/`, including
`vibe-coding-signal-light` (shows Claude Code / Codex / CI state as a traffic
light) and `claude-bot`. These achieve the same result as Ulanzi Studio's
agent-hook integration, but over a broker you control.

Before pointing the device at a broker, `mqtt-check.py` (see the
[README](README.md#quick-start)) verifies the credentials from the raw MQTT
CONNACK code.
