# tc002 custom runtime cli

`tc002` is a go client for the custom v2 runtime in [`../runtime`](../runtime).
its wire api is **`/api/v1`**, as implemented in
[`runtime/src/net/api.zig`](../runtime/src/net/api.zig). the stock firmware api
is a different interface. no stock endpoints or `/api/v2` paths are used.

## build and run

requires go 1.24 or later.

```sh
cd api-client-v2
go build -o bin/tc002 ./cmd/tc002
./bin/tc002 --help
# alternatively, install into your go bin directory:
go install ./cmd/tc002
```

set a device address and the path to its credentials file:

```sh
export TC002_SERVER=192.168.1.50
export TC002_TOKEN_FILE="$HOME/.config/tc002/tokens"
tc002 status
tc002 scene art --generator plasma --seed 5
tc002 scene art --generator terrain --seed 7
tc002 scene clock --font mini --colour-mode gradient --colour 2060ff --colour2 60c0ff
tc002 notify 'hello' --colour 00ff80 --duration 4 --transition swipe_in --direction left
tc002 scene art --transition ripple --easing ease_out --transition-ms 900
tc002 notify doorbell --name door --stack --hold   # queues behind the current one, stays until dismissed
tc002 dismiss door
tc002 scene clock --font block --fade
tc002 brightness 60
tc002 power off
tc002 input rotary cw --steps 3
```

`--server` / `-s` accepts a host, host:port, or an http/https root url. an explicit
`/api/v1` suffix is also accepted. the runtime serves plain http on port 80;
https is useful with a trusted tls proxy. environment proxies are not used.

## authentication

use `--token`, `--token-file`, `TC002_TOKEN`, or `TC002_TOKEN_FILE`.
credentials files support the runtime's labelled `control=` and `admin=` lines,
a single 64-character hex token, and the legacy 64-byte binary pair. named
`client=<name>,<scope|scope|...>,<64 hex>` rows in runtime credential files coexist with the built-in tokens; the older `read`/`control` rank spelling is still accepted when reading, so a file written before scopes keeps working.
a 64-character hex file is interpreted as one token before considering the
legacy binary form.

commands that need admin authority automatically select the admin entry from
a labelled file; `--admin` selects it for other commands. single/direct tokens
are sent as supplied, and the device determines their authority. a read-only
named token can be supplied as a single-token file or through `TC002_TOKEN`.

explicit connection flags override the corresponding environment defaults.
an explicit `--token-file` overrides `TC002_TOKEN`; an explicit `--token`
takes precedence over every token file. environment tokens are never printed
in help. keep credential files private: the runtime's plain-http profile sends
bearer tokens over the network. token creation and rotation intentionally print
the new secret once; use `--out` to save the response when appropriate.

## commands

| command | purpose | authority |
| --- | --- | --- |
| `status`, `scenes`, `icons` | runtime status and catalogues | read |
| `scene <clock\|art\|canvas>` | select the base scene and clock style | control |
| `brightness`, `reseed`, `arm-stream`, `power` | display actions | control |
| `input <control> <event>`, `notify [text]`, `dismiss [name]`, `frame` | input and temporary overlays | control |
| `screen [--format json\|raw]` | current framebuffer | read |
| `logs [--after n]` | one page of the supervisor log ring | control |
| `events` | continuous server-sent event stream | read |
| `config get`, `config set`, `config save` | effective and persisted settings | read; admin for changes |
| `mqtt get`, `mqtt set`, `mqtt status` | broker settings and connection state | admin; read for status |
| `ntfy get`, `ntfy set` | subscription settings and status | admin |
| `canvas get`, `canvas put`, `canvas patch`, `canvas clear` | canvas documents and values | read; admin for put; control for patch/clear |
| `sprites list`, `sprites put`, `sprites delete` | rgb888 sprites | `status` to list; **`content` (admin) for put and delete** |
| `sounds list`, `sounds upload`, `sounds delete`, `sounds play`, `sounds stop` | stored sounds and playback | read; admin for upload/delete; control for playback |
| `berry`, `scripts list`, `scripts get`, `scripts put`, `scripts run`, `scripts delete` | berry interpreter and script store | control for `berry` and `scripts list`; **`scripts` (admin) for get, put, run and delete** — reading a script back is not a control route |
| `tokens list`, `tokens create`, `tokens rotate`, `tokens revoke` | named tokens | admin |
| `reboot` | reboot the clock behind its "rebooting..." notice | admin (the `reboot` scope) |
| `request <method> <path>` | direct request beneath `/api/v1` | route-dependent; use `--admin` when needed |
| `completion <bash\|zsh>` | print completion script | offline |

use `tc002 <command> --help` for parameters. enum values and ranges are checked
before a request. settings flags use hyphens; their json wire keys use underscores.
explicit zero and false values are retained. omitted settings retain their current
values; other omitted fields use runtime defaults.

```sh
tc002 config set --timezone Europe/Amsterdam --clock-font block --night=true
tc002 config set --sound-enabled=false --expected-revision 12
tc002 config save --revision 13
tc002 config set --generator-params '[{"scene":"cube","name":"speed","value":"2"}]'
tc002 mqtt set --enabled=true --host 192.168.1.2 --port 1883
tc002 ntfy set --url https://ntfy.sh --topic clock
# --token authenticates to the device; --subscription-token configures ntfy:
tc002 ntfy set --subscription-token '<ntfy-token>'
tc002 config set --clock-fade   # the block face fades into each new second
tc002 tokens create dashboard --scope status --scope screen
tc002 tokens create ops --scope status --scope reboot
tc002 tokens rotate dashboard  # keeps the existing scopes unless --scope is supplied
```

settings and canvas commands accept `--data` with a json object, `@file`, or `-`
for stdin. `--data` cannot be combined with individual body-field flags. complex
schema validation is performed by the runtime, and its error response is preserved.
use json input to install an ntfy `ca` pem certificate or to supply nested canvas
and generator data. `scenes` returns generator parameter names, types and choices.

```sh
tc002 canvas put --data @canvas.json
tc002 canvas patch --data '{"values":[{"id":"temp","text":"21"}]}'
printf '%s' '{"brightness":30}' | tc002 config set --data -
tc002 request GET /status
tc002 request GET /logs --query after=12
tc002 --admin request PATCH /config --data '{"brightness":30}'
```

## notifications

`notify` replaces the current notification unless `--stack` queues it behind; `--hold`
keeps it up until a `dismiss`. `--name` (1..255 letters, digits, `-` or `_`) is what a
dismissal finds it by; `dismiss` alone drops the current one. there are eight slots
including the active one, and the runtime refuses a stack into a full queue.

```sh
tc002 notify doorbell --name door --stack --hold
tc002 notify parcel --name delivery --stack --duration 10
tc002 dismiss door       # the first notification named door, active before waiting
tc002 dismiss            # the current one only
```

a notification may be a canvas document instead of a line of text: `--data` takes the
same `elements` a `canvas put` takes, plus any notify field, and the optional text
argument becomes the summary the event stream carries. `--data` does not mix with the
field flags, as everywhere else.

```sh
tc002 notify --data @notice.json                 # {"elements":[…],"hold":true,"name":"updating"}
tc002 notify parcel --data '{"elements":[{"type":"rect","at":[0,0],"size":[52,16],"colour":"00ff80"}],"duration_s":10}'
tc002 canvas put --data @canvas.json --persist=false   # shown, not written to flash; a restart brings the saved one back
```

`reboot` sends `POST /reboot`, which takes no body and needs the `reboot` scope: the
admin entry of a labelled file is selected for it, as for every admin command.

## home assistant controls

```sh
tc002 config set --discovery --discovery-controls
tc002 config set --discovery-controls=false
```

writable discovery is off by default. enabling it also allows the documented clock/time/night
settings to be changed by broker writers. other privileged settings remain http-only.

## files and streaming

```sh
tc002 screen --format raw --out screen.rgb
tc002 frame screen.rgb --duration 3 --transition dissolve
tc002 frame --colour ff0000 --duration 2
tc002 sprites put sun sun-8x8.rgb
tc002 scripts put demo demo.be
tc002 scripts get demo --out demo.be
tc002 scripts run demo
tc002 sounds upload chime chime.wav
tc002 sounds play chime --volume 40 --loop=false
tc002 events
```

file inputs accept `-` for stdin. frames are exactly 2496 bytes (52 × 16 rgb888);
sprites are 192 or 768 bytes (8 × 8 or 16 × 16 rgb888). scripts are text/plain,
at most 8000 bytes. sounds are at most 192 kib and uploaded in ordered 4096-byte
chunks, with `final=1` on the last chunk. the device validates the wav format.
an upload stops at its first failed chunk and does not retry automatically.

successful json responses are indented by default; `--compact` emits compact json.
text, binary and event responses retain their original bytes. `--out` writes the
response to a file. ordinary responses are limited to 4 mib; error bodies to 8 kib.
errors go to stderr with a nonzero exit status. no successful output is printed
for a failed request. exit codes are 0 for success, 1 for runtime/connection errors,
2 for command syntax or local payload validation errors, and 130 for cancellation.

`--timeout` defaults to 8 seconds. for `events`, it limits connecting and receiving
headers, while the event body streams until the server closes it or you interrupt.
requests follow no redirects and perform no automatic retries. optional
`--request-id` and `--epoch` apply to scene, action, input, notification and frame
commands; otherwise the runtime generates ids and supplies its current epoch.

stream-session creation, palette and deletion routes are present in the runtime
but currently return `503 not_implemented`. they remain accessible through
`request`; `events` is the separately implemented event stream. `arm-stream`
only sends the runtime's existing arm action. the current base scenes are clock,
art and canvas; there is no `scene ip`: the address is a page of the device menu,
and its layout is the `ip_mode` setting.

## shell completion

completion includes command names, flags, enum values, contextual input events,
and filenames (including `--data @file`). it makes no device requests and needs
no credentials. `make completions` regenerates the checked-in scripts using
[cobra's completion support](https://github.com/spf13/cobra/blob/main/site/content/completions/_index.md).

bash requires the standard
[bash-completion helpers](https://github.com/scop/bash-completion#installation)
to be installed and loaded first (version 1.x for macos's system bash 3.2, or a
compatible 2.x version for modern bash). then, for the current shell:

```bash
# load your system's bash-completion setup first
source <(tc002 completion bash)
# or: source /path/to/api-client-v2/completions/tc002.bash
```

zsh, for the current shell:

```zsh
autoload -Uz compinit
compinit
source <(tc002 completion zsh)
# or: source /path/to/api-client-v2/completions/_tc002
```

for persistent bash completion, put the source line in `~/.bashrc`. for zsh,
put it in `~/.zshrc` after `compinit`. the `tc002` executable must be on `PATH`
for dynamic parameter completion.

## development

```sh
go test -race ./...
go vet ./...
make completions
bash -n completions/tc002.bash
zsh -n completions/_tc002
```

tests use local http servers and synthetic tokens; they do not alter a device.
version metadata can be set with:

```sh
go build -ldflags '-X github.com/atomicstack/tc002-customisation/api-client-v2/internal/cli.Version=1.0.0' -o bin/tc002 ./cmd/tc002
```
