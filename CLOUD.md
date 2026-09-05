# Ulanzi TC002 — cloud authentication and outbound traffic

What the device sends to Ulanzi's servers, how it authenticates to them, and
why that matters.

Besides the local API (`HTTP-API.md`), the firmware talks
**outbound** to Ulanzi's cloud (and, separately, to seven NTP servers — see
[DEVICE.md](DEVICE.md#time)), and three keys in `/data/setting.ini` exist only
for the cloud:

| `setting.ini` key | What it is |
|-------------------|------------|
| `secretKey` | 32-hex per-device credential, issued by the cloud at registration |
| `authToken` | HS256 JWT (claims `deviceSn`, `pid`, `ts`, `exp`), 2-hour lifetime |
| `authRefreshToken` | 32-hex refresh credential, 7-day lifetime |
| `tokenExpireTime`, `refreshTokenExpireTime` | unix expiry of the two above |

The logic is `awtrix::AuthManager` (`src/awtrix/http/AuthManager.cpp`) inside
the app library `/res/lib/libzkgui.so`. The base URL is hardcoded:

```
http://api.ulanzistudio.com/api/uclock
```

---

## Flow

1. **Register** — `POST /device/register` with `{deviceSn, macAddress,
   initTimestamp}`. No credential is required. The response carries
   `secretKey`, which the device stores.
2. **Token** — `POST /auth/token` with `deviceSn`, a unix timestamp and

   ```
   signature = md5(secretKey + deviceSn + timestamp)   # lowercase hex
   ```

   The response carries the JWT, a `refreshToken` and `expireIn` (7200 s).
   The formula was confirmed by recomputing a signature the device had logged.
3. **Refresh** — when the JWT is expiring, `POST /auth/refresh` with the refresh
   token returns a new JWT (and sometimes a new refresh token). If that fails
   the device signs a fresh `/auth/token`; if *that* fails it re-registers. A
   changed serial or MAC also clears the stored auth state.

---

## What the token is for

Every cloud call carries `Authorization: Bearer <authToken>` and, from the
adjacent string table, a `DeviceSN` header:

| Cloud path | Used by |
|------------|---------|
| `/weather/weatherInfo` | weather app (`city`) |
| `/follower/<platform>` | social apps' follower counts (`uid`) |
| `/tokenInfo`, `/authorizeUrl` | social OAuth status and login |
| `/caldav/fetchServerEvents` | iCloud / Feishu / DingTalk / WeCom calendars — sends `serverUrl`, `period` and the stored `username` / `password`; **the cloud performs the CalDAV fetch** |
| `/caldav/fetchWebCalEvents` | Google / Outlook calendars (`url`) |
| `/firmware/checkUpdate` | the local `/checkUpdate` endpoint |

Nothing local depends on these keys: the HTTP API, the web pages and MQTT never
read them, no local endpoint returns them, and Ulanzi Studio does not reference
them either.

---

## Observations

- **Plain HTTP.** The base URL is `http://`, and `api.ulanzistudio.com` answers
  on port 80 without redirecting to HTTPS. `logcat` shows successful
  registration, token issue and weather fetches against it. So the secret key
  (in the register response), every bearer token, and any CalDAV
  username/password cross the internet unencrypted. This is inferred from the
  URL, the server's behaviour and the logs, not from a packet capture.
- **The secret key is logged.** `AuthManager` prints it to `logcat` at
  registration and again inside `calculateSignature`. Anyone with adb reads it.
- **Registration is unauthenticated** and needs only serial + MAC, both of
  which the local `/getBase` hands to anyone on the LAN. Whether a repeat
  registration rotates the key was **not tested**, since doing so could
  invalidate a live device's credential.
- **Calendar credentials leave your network.** Configuring a CalDAV provider
  means Ulanzi's server receives the server URL and password and does the
  fetch on the device's behalf.

These are summarised alongside the local-API findings in
`SECURITY.md`.

---

## Mitigation

If weather, social counts, calendars and the update check are not needed, block
the device's outbound internet at the router — **except UDP/123 to the seven
NTP IPs listed in [DEVICE.md](DEVICE.md#time)**, or redirect that to a local
NTP server. The list is IP literals, not names, so the redirect has to be a
destination-NAT rule rather than DNS; the other option is to write your own
server's address into the app library with `tc002-ntp-patch.py --server`
(same section). The device has no RTC and gets its time only from those
servers, so a blanket block leaves the clock at 1970 after the next reboot. The local
API and MQTT do not involve the cloud, so they should keep working; running the
device that way has not been tested here for side effects such as retry spam
in `logcat`.
