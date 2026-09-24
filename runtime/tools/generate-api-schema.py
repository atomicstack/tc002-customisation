#!/usr/bin/env python3
"""generate compact, offline api contracts; run with --check to detect drift.

wire fields/types and route scopes come directly from api.zig. semantic constraints
and response models below mirror the parser and netd serializers; contract tests
exercise these separately. requires only the python standard library.
"""
import argparse
import copy
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
API = (ROOT / 'src/net/api.zig').read_text()
DIALECT = 'https://json-schema.org/draft/2020-12/schema'


def string(**kw):
    return dict(type='string', **kw)


def integer(low=0, high=4294967295, **kw):
    return dict(type='integer', minimum=low, maximum=high, **kw)


def enum(*values):
    return dict(type='string', enum=list(values))


def array(items, **kw):
    return dict(type='array', items=items, **kw)


def obj(properties, required=None, **kw):
    return dict(type='object', properties=properties, required=list(properties) if required is None else required, additionalProperties=False, **kw)


def ref(name):
    return {'$ref': '#/$defs/' + name}


def nullable(schema):
    return {'anyOf': [schema, {'type': 'null'}]}


def nonnull(name):
    return {'required': [name], 'properties': {name: {'not': {'type': 'null'}}}}


def condition(name, value, then):
    return {'if': {'properties': {name: {'const': value}}, 'required': [name]}, 'then': then}


def enum_source(path, name):
    source = (ROOT / 'src' / path).read_text()
    body = re.search(r'pub const ' + name + r' = enum(?:\([^)]*\))? \{(.*?)\n?\};', source, re.S).group(1)
    body = re.sub(r'//[^\n]*', '', body).split('pub fn')[0].split('fn ')[0]
    return enum(*re.findall(r'(?:^|,)\s*(\w+)\s*(?:=\s*\d+)?\s*(?=,|$)', body.strip()))


BOOL = {'type': 'boolean'}
COLOUR = string(pattern='^[0-9a-fA-F]{6}$')
REQUEST_ID = string(pattern='^[0-9a-fA-F]{1,16}$', description='caller id for retries; generated if omitted; 1..16 hex digits')
NOTIFICATION_NAME = string(minLength=1, maxLength=32, pattern=r'^[A-Za-z0-9_-]+(?![\s\S])')
NAME = string(pattern='^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,31}$')
ID = string(minLength=1, maxLength=8)
OCTET = r'(?:[0-9]{1,2}|[01][0-9]{2}|2[0-4][0-9]|25[0-5])'
IPV4 = string(pattern='^(?:' + OCTET + r'\.){3}' + OCTET + '$', description='dotted ipv4 address; each octet must be 0..255')
BASE = enum_source('scene/arbiter.zig', 'Base')
GENERATOR = enum_source('scene/scene.zig', 'Generator')
SCOPES = enum_source('net/clients.zig', 'Scope')
SCOPES['enum'].remove('tokens')
FONT = enum_source('scene/clockfont.zig', 'Font')
DIGITS = enum_source('scene/clockfont.zig', 'DigitStyle')
EFFECT = enum_source('panel/transition.zig', 'Effect')
DIRECTION = enum_source('panel/transition.zig', 'Direction')
EXIT = enum_source('panel/transition.zig', 'Exit')
SAMPLES = array(integer(0, 255), maxItems=52)
HEX_SAMPLES = string(pattern='^(?:[0-9a-fA-F]{2}){0,52}$')
TRANSITION = dict(transition=EFFECT, direction=DIRECTION, transition_ms=integer(0, 5000), exit=EXIT)


def wire_schemas():
    schemas, optional = {}, {}
    wire = API.split('// json wire schemas (request bodies)', 1)[1].split('fn bad(', 1)[0]
    for name, body in re.findall(r'const (\w+Body) = struct \{(.*?)\};', wire, re.S):
        body = re.sub(r'//[^\n]*', '', body)
        props, required = {}, []
        optional[name] = set()
        for field in body.split(','):
            field = field.strip()
            if not field:
                continue
            match = re.fullmatch(r'(?:@"([^"]+)"|(\w+)):\s*(.*?)(?:\s*=\s*(.*))?', field)
            if not match:
                raise ValueError('unrecognized wire field: ' + field)
            quoted, plain, typ, default = match.groups()
            key = quoted or plain
            if typ.startswith('?'):
                optional[name].add(key)
                typ = typ[1:]
            if typ == '[]const u8':
                schema = string()
            elif typ == 'bool':
                schema = dict(BOOL)
            elif typ == 'f64':
                schema = {'type': 'number'}
            elif re.fullmatch(r'u\d+', typ):
                schema = integer(0, 2 ** int(typ[1:]) - 1)
            elif typ == '[2]i16':
                schema = array(integer(-32768, 32767), minItems=2, maxItems=2)
            elif typ == 'SampleData':
                schema = copy.deepcopy(SAMPLES)
            elif typ.startswith('[]const '):
                child = typ.removeprefix('[]const ')
                schema = array(string() if child == '[]const u8' else ref(child))
            elif typ.endswith('Body'):
                schema = ref(typ)
            else:
                raise ValueError('unrecognized wire type: ' + typ)
            if default is None:
                required.append(key)
            elif default != 'null':
                schema['default'] = json.loads(default)
            props[key] = schema
        schemas[name] = obj(props, required)
    return schemas, optional


def request_schemas():
    schemas, optional = wire_schemas()
    def update(model_name, **fields):
        schemas[model_name]['properties'].update(copy.deepcopy(fields))
    for name in ('SceneBody', 'NotifyBody'):
        update(name, **TRANSITION)
    for name in ('SceneBody', 'ActionBody', 'InputBody', 'NotifyBody', 'DismissNotifyBody'):
        update(name, request_id=REQUEST_ID)
    clock_fields = dict(font=FONT, colour_mode=enum('solid', 'gradient'), colour=COLOUR, colour2=COLOUR, gradient=enum('horizontal', 'vertical', 'diagonal'), digits=DIGITS)
    update('ClockBody', **clock_fields)
    update('SceneBody', base=BASE, generator=GENERATOR)
    update('GenParamBody', scene=GENERATOR, value=string(description='parameter value as text: choice name, decimal number, rrggbb colour, or on/off/true/false; inspect /scenes for per-generator names and ranges'))
    update('ActionBody', action=enum('brightness', 'reseed', 'arm_stream', 'power'))
    schemas['ActionBody']['allOf'] = [condition('action', 'brightness', {**nonnull('brightness'), 'properties': {'brightness': integer(1, 100)}}), condition('action', 'power', nonnull('power'))]
    update('InputBody', control=enum('left', 'middle', 'right', 'knob', 'rotary'), event=enum('press', 'release', 'click', 'long', 'cw', 'ccw'), steps=integer(1, 16, default=1))
    schemas['InputBody']['allOf'] = [{'if': {'properties': {'control': {'const': 'rotary'}}}, 'then': {'properties': {'event': enum('cw', 'ccw')}}, 'else': {'properties': {'event': enum('press', 'release', 'click', 'long'), 'steps': {'const': 1}}}}]
    update('DismissNotifyBody', name=NOTIFICATION_NAME)
    update('NotifyBody', name=NOTIFICATION_NAME, text=string(minLength=1, maxLength=128, pattern='^[ -~]+$'), elements=array(ref('ElementBody'), minItems=1, maxItems=24), colour=COLOUR, duration_s=integer(1, 300, default=5))
    update('ConfigBody', brightness=integer(1, 100), base=BASE, generator=GENERATOR, timezone=string(minLength=1, maxLength=64, description='timezone name supported by the runtime timezone table'), ntp_server=IPV4, ntp_interval_s={'type': 'integer', 'enum': [300, 600]}, frame_timeout_ms=integer(100, 2000), metrics_interval_s={'anyOf': [{'const': 0}, integer(10, 3600)]}, discovery_prefix=string(minLength=1, maxLength=64), ip_mode=enum('lines', 'mini', 'scroll', 'big'), night_brightness=integer(1, 100), night_lead_min=integer(0, 120), latitude={'type': 'number', 'minimum': -90, 'maximum': 90}, longitude={'type': 'number', 'minimum': -180, 'maximum': 180}, berry_heap_kb=integer(16, 256), berry_handler_ms=integer(10, 1000), battery_shutdown_mv=integer(3000, 4000), battery_grace_s=integer(0, 300), generator_params=array(ref('GenParamBody'), maxItems=8))
    update('ConfigBody', sound_volume=integer(1, 100))
    if 'discovery_controls' in schemas['ConfigBody']['properties']:
        update('ConfigBody', discovery_controls=dict(BOOL, default=False, description='opt in to writable home assistant discovery and the restricted mqtt settings command; discovery must also be enabled for entities'))
    if 'mdns' in schemas['ConfigBody']['properties']:
        update('ConfigBody', mdns=dict(BOOL, default=True, description='the mdns responder: while on the clock answers for tc002-<mac>.local and _tc002._tcp; off withdraws the name'))
    for key, val in clock_fields.items():
        update('ConfigBody', **{'clock_' + ('digit' if key == 'digits' else key): val})
    schemas['ConfigBody']['allOf'] = [{'if': nonnull('latitude'), 'then': nonnull('longitude')}, {'if': nonnull('longitude'), 'then': nonnull('latitude')}]
    update('MqttBody', host=IPV4, port=integer(1, 65535))
    for name in ('username', 'password', 'client_id', 'prefix'):
        update('MqttBody', **{name: string(maxLength=64, **({'writeOnly': True} if name == 'password' else {}))})
    update('NtfyBody', url=string(maxLength=64, pattern=r'^(?:$|https?://[^\s]+$)', description='empty disables the url; http://host[:port][/prefix] or https://host[:port][/prefix]'), topic=string(maxLength=64, pattern=r'^[A-Za-z0-9_-]*(?![\s\S])'), duration_s=integer(1, 300), ca=string(maxLength=3500, description='pem certificate containing -----BEGIN CERTIFICATE-----, or empty to remove'))
    for name in ('token', 'username', 'password'):
        update('NtfyBody', **{name: string(maxLength=64, **({'writeOnly': True} if name != 'username' else {}))})
    update('TokensBody', name=NAME, scopes=array(SCOPES, minItems=1))
    update('RotateBody', scopes=array(SCOPES, minItems=1))
    update('SoundBody', name=NAME)
    schemas['SoundBody']['anyOf'] = [{'properties': {'stop': {'const': True}}, 'required': ['stop']}, {**nonnull('name'), 'properties': {'name': NAME, 'volume': nullable(integer(1, 100))}}]
    update('AnimateBody', kind=enum('hue', 'bounce', 'scramble', 'scroll', 'blink', 'pulse', 'typewriter', 'sweep'), ms=integer(1, 65535), phase=integer(0, 100), axis=enum('x', 'y'))
    update('ElementBody', type=enum_source('scene/canvas.zig', 'Kind'), id=ID, colour=COLOUR, background=COLOUR, over=COLOUR, accent=COLOUR, sprite=ID, font=enum('small', 'mini', 'block', 'big'), align=enum('left', 'centre', 'right'), style=enum('line', 'bars', 'area'), data=SAMPLES, data_hex=HEX_SAMPLES, text=string(maxLength=256), label=string(maxLength=256), value_text=string(maxLength=256), size=array(integer(0, 32767), minItems=2, maxItems=2))
    update('ValueBody', id=ID, text=string(maxLength=64), colour=COLOUR, data=SAMPLES, data_hex=HEX_SAMPLES)
    update('CanvasBody', elements=array(ref('ElementBody'), maxItems=24), persist={**BOOL, 'default': True, 'description': 'false shows the document without writing it to flash; a restart brings the last persisted one back'})
    update('PatchBody', values=array(ref('ValueBody'), maxItems=24))
    # optional zig values accept explicit null, which means the same as absence.
    for name, fields in optional.items():
        for key in fields:
            schemas[name]['properties'][key] = nullable(schemas[name]['properties'][key])
    common = set('type id age_ms at size tile row of colour animate'.split())
    specific = dict(text='text font align', rect='filled', line='to', circle='r filled', pixel='', bar='value background vertical', sparkline='data data_hex style min max threshold over', icon='icon', sprite='sprite', tile='icon sprite label value_text accent')
    rules = []
    for kind, fields in specific.items():
        forbidden = set(schemas['ElementBody']['properties']) - common - set(fields.split())
        then = {'properties': {key: {'type': 'null'} for key in sorted(forbidden)}}
        required = {'text': 'text', 'line': 'to', 'icon': 'icon', 'sprite': 'sprite', 'tile': 'value_text'}.get(kind)
        if required:
            then['allOf'] = [nonnull(required)]
        if kind == 'tile':
            then['anyOf'] = [nonnull('icon'), nonnull('sprite')]
        rules.append(condition('type', kind, then))
    rules += [{'if': nonnull('tile'), 'then': {'allOf': [nonnull('of')], 'properties': {'row': {'type': 'null'}, 'at': {'type': 'null'}, 'size': {'type': 'null'}}}}, {'if': nonnull('row'), 'then': {'allOf': [nonnull('of')], 'properties': {'tile': {'type': 'null'}, 'at': {'type': 'null'}, 'size': {'type': 'null'}}}}, {'if': nonnull('of'), 'then': {'anyOf': [nonnull('tile'), nonnull('row')]}}]
    for motion in ('scramble', 'typewriter', 'scroll', 'sweep'):
        rules.append({'if': {'allOf': [nonnull('animate')], 'properties': {'animate': {'properties': {'kind': {'const': motion}}}}}, 'then': {'properties': {'type': {'const': 'sparkline' if motion == 'sweep' else 'text'}}}})
    schemas['ElementBody']['allOf'] = rules
    schemas['ElementBody']['description'] = 'drawing primitive; at/size are pixel coordinates, or use zero-based tile/row with of. shared document pools: 256 text bytes and 1024 sample bytes. tile/row indices are clamped to the supplied count; zero of behaves as one. sprite and icon names are resolved by the runtime.'
    schemas['ValueBody']['anyOf'] = [nonnull(key) for key in ('text', 'data', 'data_hex', 'value', 'colour')]
    schemas['ValueBody']['allOf'] = [{'if': nonnull('text'), 'then': {'properties': {'data': {'type': 'null'}, 'data_hex': {'type': 'null'}}}}]
    return schemas


def response_schemas(schemas):
    n, text, b = integer(), string(), BOOL
    def model(name, fields, required=None):
        schemas[name] = obj(fields, required)
        return ref(name)
    clock = obj(dict(font=FONT, colour_mode=enum('solid', 'gradient'), colour=COLOUR, colour2=COLOUR, gradient=enum('horizontal', 'vertical', 'diagonal'), spread=integer(0, 255), digits=DIGITS))
    model('ErrorResponse', dict(error=text, message=text, request_id=string(pattern='^[0-9a-f]{16}$')))
    model('AppliedEvent', dict(revision=n, age_ms=n, cmd=enum('set_base', 'select_generator', 'notify', 'raw', 'brightness', 'reseed', 'power', 'set_ip_mode', 'set_clock_style', 'arm_stream', 'overlay_expired', 'dismiss_notify'), name=string(maxLength=32, pattern=r'^[A-Za-z0-9_-]*(?![\s\S])'), stack=b, hold=b, source=enum('local', 'api', 'ntfy', 'input'), base=BASE, generator=GENERATOR, text=text, colour=COLOUR, duration_s=n, brightness=n, seed=n, power=b, ip_mode=enum('lines', 'mini', 'scroll', 'big'), clock=clock), ['revision', 'age_ms', 'cmd', 'source'])
    model('AppliedResponse', dict(status={'const': 'applied'}, revision=n, epoch=n, request_id=string(pattern='^[0-9a-f]{16}$')))
    model('SavedResponse', dict(status={'const': 'saved'}, saved_revision=n))
    model('BerryResult', dict(status={'const': 'ok'}, name=text, note=text), ['status', 'name'])
    model('SoundResult', dict(status={'const': 'ok'}, used=n, budget=n))
    model('BerryResponse', dict(state=enum('off', 'starting', 'running', 'failed'), heap_bytes=n, heap_used=n, heap_high_water=n, alloc_failures=n, stops=n))
    model('NtfyStatus', dict(state=enum('off', 'connecting', 'subscribed', 'error'), messages=n, error=text))
    model('MqttStatus', dict(enabled=b, connected=b, state=enum_source('net/mqtt.zig', 'State'), reconnect_delay_s=n, reconnects=n, last_error=text))
    model('MqttResponse', dict(enabled=b, host=text, port=integer(0, 65535), username=text, client_id=text, prefix=text, tls=b, password_set=b))
    model('NtfyResponse', dict(enabled=b, url=text, topic=text, username=text, token_set=b, password_set=b, duration_s=n, insecure=b, ca_set=b, status=ref('NtfyStatus')))
    model('ConfigResponse', dict(revision=n, saved_revision=n, brightness=n, base=BASE, generator=GENERATOR, timezone=text, ntp=obj(dict(server=nullable(text), interval_s=n)), frame_timeout_ms=n, metrics_interval_s=n, discovery=obj(dict(enabled=b, controls=dict(b, default=False), prefix=text)), clock=clock, ip_mode=enum('lines', 'mini', 'scroll', 'big'), night=obj(dict(enabled=b, brightness=n, lead_min=n)), latitude=nullable({'type': 'number'}), longitude=nullable({'type': 'number'}), location=nullable(obj(dict(latitude={'type': 'number'}, longitude={'type': 'number'}, source=enum('timezone', 'set')))), generators={'type': 'object', 'additionalProperties': {'type': 'object', 'additionalProperties': {'type': ['string', 'integer']}}}, berry=obj(dict(enabled=b, heap_kb=n, handler_ms=n)), sound=obj(dict(enabled=b, volume=n)), battery=obj(dict(shutdown=b, shutdown_mv=n, grace_s=n)), allowed_origins=array(text)))
    model('ScreenResponse', dict(width={'const': 52}, height={'const': 16}, epoch=n, revision=n, brightness=n, power=b, rgb_base64=string(contentEncoding='base64', contentMediaType='application/octet-stream', minLength=3328, maxLength=3328, description='2496 row-major rgb888 bytes, 52 columns by 16 rows')))
    model('LogsResponse', dict(next=n, lines=array(obj(dict(seq=n, text=text)))))
    model('SpritesResponse', dict(slots={'const': 8}, sprites=array(obj(dict(id=ID, width=integer(8, 16), height=integer(8, 16))))))
    model('IconsResponse', dict(size={'const': 8}, names=array(text)))
    model('SoundsResponse', dict(used=n, budget=n, sounds=array(obj(dict(name=NAME, bytes=n)))))
    model('ScriptsResponse', dict(used=n, budget=n, scripts=array(obj(dict(name=NAME, bytes=n, compiled=b)))))
    model('TokensResponse', dict(clients=array(obj(dict(name=NAME, scopes=array(SCOPES), created_s=n, last_used_s=n))), max=n))
    model('TokenResponse', dict(name=NAME, scopes=array(SCOPES), token=string(pattern='^[0-9a-f]{64}$', description='returned only once, on issue or rotation; store securely')))
    model('CanvasResponse', dict(revision=n, saved_revision=n, persist=b, age_ms=n, elements=array(ref('ElementBody'), maxItems=24), limits=obj(dict(elements={'const': 24}, text_bytes={'const': 256}, data_bytes={'const': 1024}, samples={'const': 52}))))
    parameter = obj(dict(name=text, kind=enum('choice', 'number', 'colour', 'toggle'), default={'type': 'integer'}, on_panel=b, choices=array(text), min={'type': 'integer'}, max={'type': 'integer'}, step={'type': 'integer'}), ['name', 'kind', 'default'])
    model('ScenesResponse', dict(bases=array(BASE), generators=array(obj(dict(index=n, name=GENERATOR, parameters=array(parameter)))), parameters={'type': 'object', 'additionalProperties': array(parameter)}, clock=obj(dict(fonts=array(FONT), colour_modes=array(text), digits=array(DIGITS), gradients=array(text), spread=array(n, minItems=2, maxItems=2), max_spread=n)), ip=obj(dict(modes=array(text))), notify=obj(dict(text_max=n, duration_s=array(n))), frame=obj(dict(bytes=n, duration_s=array(n))), transitions=obj(dict(effects=array(EFFECT), directions=array(DIRECTION), exits=array(EXIT), duration_ms=array(n)))))
    status = dict(epoch=n, revision=n, renderer=enum('none', 'starting', 'running', 'stopping', 'unknown'), base=BASE, generator=GENERATOR, seed=n, overlay=enum('none', 'notify', 'frame', 'stream_arming', 'unknown'), brightness=n, power=b, presented=integer(0, 18446744073709551615), fps=nullable({'type': 'number'}), uptime_s=n, memory_available_kb=n, memory_total_kb=n, cpu_pct=nullable(n), restarts=n, network=obj(dict(ip=nullable(text))), time=obj(dict(state=enum('unsynced', 'synced', 'stale', 'unknown'), age_s=nullable(n))), clock=clock, ip_mode=text, menu=obj(dict(open=b, kind=enum('device', 'scene'), state=enum('browsing', 'adjusting', 'confirming'), item=text, index=n, items=n, scene=BASE), ['open']), night=obj(dict(enabled=b, phase=nullable(text), held=b, today=nullable(obj(dict(dawn=nullable({'type': 'integer'}), sunrise=nullable({'type': 'integer'}), sunset=nullable({'type': 'integer'}), dusk=nullable({'type': 'integer'}), sun_up=b))))), ntfy=ref('NtfyStatus'), berry=ref('BerryResponse'), config_revision=n, saved_revision=n, transport={'const': 'plaintext'}, mqtt=ref('MqttStatus'), build=text, boot_id=string(pattern='^[0-9a-f]{8}$'), sample_age_ms=n, device_id=text, load_1m=nullable({'type': 'number'}), memory_free_kb=n, tmpfs_used_kb=nullable(n), tmpfs_total_kb=n, flash_used_kb=n, flash_total_kb=n, wifi=obj(dict(rssi_dbm=nullable({'type': 'integer'}), quality=nullable(n))), cpu_pct_by_process=obj({key: nullable({'type': 'number'}) for key in ('supervisor', 'renderer', 'netd')}), battery=obj(dict(millivolts=nullable(n), percent=nullable(n), usb_present=nullable(b))), config_saves=obj(dict(count=n, failures=n, bytes=n, last_ms=nullable(n))))
    status['net'] = obj(dict(interface={'const': 'wlan0'}, **{key: integer(0, 18446744073709551615) for key in 'rx_bytes tx_bytes rx_packets tx_packets rx_errors rx_dropped tx_errors tx_dropped'.split()}, rx_bytes_per_s=nullable(n), tx_bytes_per_s=nullable(n)))
    status.update({key: n for key in 'memory_cached_kb memory_dirty_kb memory_writeback_kb memory_slab_kb'.split()})
    model('StatusResponse', status)


def build():
    schemas = request_schemas()
    response_schemas(schemas)
    requests = {('/scene', 'put'): 'SceneBody', ('/action', 'post'): 'ActionBody', ('/config', 'patch'): 'ConfigBody', ('/config/save', 'post'): 'SaveBody', ('/notify', 'post'): 'NotifyBody', ('/notify/dismiss', 'post'): 'DismissNotifyBody', ('/canvas', 'put'): 'CanvasBody', ('/canvas', 'patch'): 'PatchBody', ('/mqtt', 'put'): 'MqttBody', ('/ntfy', 'put'): 'NtfyBody', ('/input', 'post'): 'InputBody', ('/sound', 'post'): 'SoundBody', ('/tokens', 'post'): 'TokensBody', ('/tokens/{name}/rotate', 'post'): 'RotateBody'}
    reads = {'/status': 'StatusResponse', '/scenes': 'ScenesResponse', '/config': 'ConfigResponse', '/icons': 'IconsResponse', '/sprites': 'SpritesResponse', '/canvas': 'CanvasResponse', '/mqtt': 'MqttResponse', '/mqtt/status': 'MqttStatus', '/ntfy': 'NtfyResponse', '/screen': 'ScreenResponse', '/logs': 'LogsResponse', '/sounds': 'SoundsResponse', '/berry': 'BerryResponse', '/berry/scripts': 'ScriptsResponse', '/tokens': 'TokensResponse'}
    notes = {
        '/config': 'read current settings or patch selected fields. expected_revision enables optimistic concurrency. accepted changes apply live and immediately attempt persistence; saved_revision == revision confirms they were saved. /config/save can retry a failed save. discovery_controls defaults to false and enables writable home assistant discovery only with discovery enabled. mqtt cmd/config cannot change credentials or discovery opt-in.',
        '/config/save': 'persist the current settings; optional revision must match. an empty body is accepted with application/json.',
        '/scene': 'select clock, art or canvas; art may select a generator and seed. clock customizations apply to this scene command.',
        '/action': 'brightness requires brightness (1..100); power requires power; reseed accepts seed; arm_stream opens the local stream-arming overlay but does not implement stream sessions.',
        '/notify': 'show 1..128 printable ascii characters; long text scrolls. stack=true queues fifo with eight slots including the active notification; otherwise replace the active notification and keep the queue. duration_s is 1..300 (default 5), starting when displayed. hold=true disables expiry; both flags default false. names are case-sensitive, 1..32 ascii letters, digits, _ or -.',
        '/notify/dismiss': 'omit name to dismiss the current notification, or provide a name to remove the first matching active or queued notification. an unknown name is a successful no-op; an empty name is invalid. dismissing the active notification promotes the next queued entry.',
        '/reboot': 'reboot the device through its reboot notice. requires the reboot scope and takes no request body.',
        '/frame': 'show exactly 2496 row-major rgb888 bytes (52 x 16), for duration_s seconds. limited to ten frames per second. query transition defaults to cut.',
        '/canvas': 'read or replace a canvas, patch values by element id, or clear it. at most 24 elements, 256 pooled text bytes, and 1024 pooled data bytes. /scene selects the canvas base; reading a document includes revision/limits which must be removed before put.',
        '/screen': 'json includes base64 rgb pixels; format=raw returns exactly 2496 rgb888 bytes.',
        '/events': 'live server-sent applied events, with keepalive comments. up to two subscribers. no replay; resync /status after reconnect or a revision gap. send authorization via a fetch streaming client.',
        '/sounds/{name}': 'upload in chunks of at most 4096 bytes. offset=0 and final=0 begins; subsequent offsets must be contiguous; final=1 commits. a separate empty final chunk is supported. stored audio must pass runtime wav validation.',
        '/berry/scripts/{name}': 'read source, store up to 8000 bytes of text/plain berry source, or delete the stored script. storing validates compilation.',
        '/berry/scripts/{name}/run': 'run the stored script. no request body is accepted; this is not an eval endpoint.',
        '/tokens': 'list names and scopes, or issue a named client token. requires the admin token (tokens scope). a named client may never hold tokens. issuance returns the secret once.',
        '/tokens/{name}/rotate': 'rotate a named client secret; omitted/empty body preserves scopes. explicit scopes replace the set. the new secret is returned once.',
        '/tokens/{name}': 'revoke a named client token; built-in admin and control tokens are outside this namespace.',
        '/ntfy': 'read redacted subscriber settings or update selected fields. token/password/ca are write-only secrets. the current put response is the full device configuration.',
        '/mqtt': 'read redacted broker settings or update selected fields. host is a dotted ipv4 address in this profile. password is never returned.',
        '/sprites/{id}': 'upload exactly 192 bytes (8 x 8) or 768 bytes (16 x 16) of rgb888, or delete a sprite. eight volatile slots.',
        '/input': 'inject button or rotary events. rotary takes cw/ccw with 1..16 steps; buttons take press/release/click/long with one step. this scope reaches the device menu and its settings/reboot actions.',
    }
    examples = {
        'SceneBody': {'base': 'clock', 'transition': 'fade', 'transition_ms': 500},
        'ActionBody': {'action': 'brightness', 'brightness': 50},
        'ConfigBody': {'discovery': True, 'discovery_controls': True},
        'SaveBody': {},
        'NotifyBody': {'text': 'hello', 'colour': 'ffffff', 'duration_s': 5},
        'DismissNotifyBody': {'name': 'door'},
        'CanvasBody': {'elements': [{'type': 'text', 'id': 'reading', 'at': [0, 0], 'text': '22c', 'colour': 'ffffff'}]},
        'PatchBody': {'values': [{'id': 'reading', 'text': '23c'}]},
        'MqttBody': {'enabled': True, 'host': '192.168.1.10', 'port': 1883},
        'NtfyBody': {'enabled': True, 'url': 'https://ntfy.sh', 'topic': 'panel-example', 'duration_s': 5},
        'InputBody': {'control': 'rotary', 'event': 'cw', 'steps': 1},
        'SoundBody': {'name': 'chime', 'volume': 50, 'loop': False},
        'TokensBody': {'name': 'home-assistant', 'scopes': ['status', 'display', 'notify']},
        'RotateBody': {},
    }
    summaries = {
        ('/status', 'get'): 'read device status',
        ('/scenes', 'get'): 'browse scenes and parameter choices',
        ('/scene', 'put'): 'select the displayed scene',
        ('/action', 'post'): 'change brightness, power or scene state',
        ('/config', 'get'): 'read device settings',
        ('/config', 'patch'): 'update device settings',
        ('/config/save', 'post'): 'save settings to persistent storage',
        ('/notify', 'post'): 'show or queue a notification',
        ('/notify/dismiss', 'post'): 'dismiss a notification',
        ('/reboot', 'post'): 'reboot the device',
        ('/frame', 'post'): 'show an rgb frame',
        ('/icons', 'get'): 'list built-in icons',
        ('/sprites', 'get'): 'list uploaded sprites',
        ('/sprites/{id}', 'put'): 'upload an rgb sprite',
        ('/sprites/{id}', 'delete'): 'delete an uploaded sprite',
        ('/canvas', 'get'): 'read the canvas document',
        ('/canvas', 'put'): 'replace the canvas document',
        ('/canvas', 'patch'): 'update canvas element values',
        ('/canvas', 'delete'): 'clear the canvas document',
        ('/mqtt', 'get'): 'read broker settings without secrets',
        ('/mqtt', 'put'): 'update broker settings',
        ('/mqtt/status', 'get'): 'read broker connection status',
        ('/ntfy', 'get'): 'read notification subscriber settings',
        ('/ntfy', 'put'): 'update notification subscriber settings',
        ('/streams', 'post'): 'create a stream session (unavailable)',
        ('/streams/{id}', 'delete'): 'delete a stream session (unavailable)',
        ('/streams/{id}/palette', 'put'): 'update a stream palette (unavailable)',
        ('/screen', 'get'): 'read the current framebuffer',
        ('/logs', 'get'): 'read a page of device logs',
        ('/events', 'get'): 'subscribe to applied state changes',
        ('/sounds', 'get'): 'list stored sounds',
        ('/sounds/{name}', 'put'): 'upload a sound in chunks',
        ('/sounds/{name}', 'delete'): 'delete a stored sound',
        ('/sound', 'post'): 'play or stop a sound',
        ('/berry', 'get'): 'read script interpreter status',
        ('/berry/scripts', 'get'): 'list stored scripts',
        ('/berry/scripts/{name}', 'get'): 'read stored script source',
        ('/berry/scripts/{name}', 'put'): 'store and compile a script',
        ('/berry/scripts/{name}', 'delete'): 'delete a stored script',
        ('/berry/scripts/{name}/run', 'post'): 'run a stored script',
        ('/input', 'post'): 'inject a button or rotary event',
        ('/tokens', 'get'): 'list named client tokens without secrets',
        ('/tokens', 'post'): 'issue a named client token',
        ('/tokens/{name}', 'delete'): 'revoke a named client token',
        ('/tokens/{name}/rotate', 'post'): 'rotate a named client token',
    }
    paths = {}
    routes = re.findall(r'\.method = \.(\w+), \.path = "(/api/v1[^"]+)", \.scope = \.(\w+)', API)
    def content(schema, media='application/json'):
        return {media: {'schema': schema}}
    def parameter(name, schema, where='query', required=False):
        return dict(name=name, **{'in': where}, required=required, schema=schema)
    for method, path, scope in routes:
        path, method = path.removeprefix('/api/v1'), method.lower()
        tag = 'scripts' if path.startswith('/berry') else path.split('/')[1]
        op = dict(operationId=method + '_' + re.sub('[^a-z0-9]+', '_', path.lower()).strip('_'), tags=[tag], summary=summaries[path, method], description=notes.get(path, 'read ' + path.strip('/').replace('/', ' ') if method == 'get' else method + ' ' + path), **{'x-required-scope': scope})
        params = []
        for name in re.findall(r'\{(\w+)\}', path):
            shape = NAME if name == 'name' else string(pattern='^[A-Za-z0-9_-]{1,8}$') if path.startswith('/sprites/') else string(minLength=1)
            params.append(parameter(name, shape, 'path', True))
        response = reads.get(path, 'AppliedResponse')
        if path == '/config/save': response = 'SavedResponse'
        if path == '/sound' or path.startswith('/sounds/'): response = 'SoundResult'
        if path.startswith('/berry/scripts/') and method != 'get': response = 'BerryResult'
        if path.startswith('/sprites/'): response = 'SpritesResponse'
        if path == '/tokens' and method == 'post' or path.endswith('/rotate'): response = 'TokenResponse'
        if path.startswith('/tokens/') and method == 'delete': response = 'TokensResponse'
        if path == '/ntfy' and method == 'put': response = 'ConfigResponse'
        op['responses'] = {'200': {'description': 'successful response', 'content': content(ref(response))}, 'default': {'description': 'request rejected or runtime unavailable; structured error with caller request id when available', 'content': content(ref('ErrorResponse'))}}
        for status, desc in {'400': 'invalid request or rejected operation', '401': 'missing or invalid bearer token', '403': 'origin denied or token missing the required scope', '503': 'runtime or local supervisor unavailable'}.items():
            op['responses'][status] = {'description': desc, 'content': content(ref('ErrorResponse'))}
        if method != 'get':
            op['responses']['409'] = {'description': 'stale epoch, revision conflict, expired session, or storage conflict', 'content': content(ref('ErrorResponse'))}
        if path == '/notify':
            op['responses']['409']['description'] += '; queue_full when stacking would exceed eight notifications'
        if (path, method) in requests:
            op['requestBody'] = {'required': path not in ('/config/save', '/tokens/{name}/rotate'), 'description': 'strict json: unknown and duplicate fields are rejected; maximum 8192 bytes and eight nesting levels; optional null means unchanged or default', 'content': content(ref(requests[path, method]))}
        if (path, method) in requests:
            op['requestBody']['content']['application/json']['example'] = examples[requests[path, method]]
        if 'requestBody' in op:
            for status, description in {'413': 'request body exceeds the route limit', '415': 'unsupported content type on a route that enforces it'}.items():
                op['responses'][status] = {'description': description, 'content': content(ref('ErrorResponse'))}
        if path == '/frame':
            op['requestBody'] = {'required': True, 'content': content(string(format='binary', minLength=2496, maxLength=2496), 'application/octet-stream')}
            params += [parameter('duration_s', integer(1, 300), required=True), parameter('request_id', REQUEST_ID), parameter('epoch', integer())] + [parameter(key, val) for key, val in TRANSITION.items()]
            op['responses']['429'] = {'description': 'frame rate exceeded or command queue full', 'content': content(ref('ErrorResponse'))}
        if path == '/screen':
            params.append(parameter('format', dict(enum('json', 'raw'), default='json')))
            op['responses']['200']['content'].update(content(string(format='binary', minLength=2496, maxLength=2496), 'application/octet-stream'))
        if path == '/logs': params.append(parameter('after', integer(default=0)))
        if path.startswith('/sprites/') and method == 'put':
            op['requestBody'] = {'required': True, 'content': content({'type': 'string', 'format': 'binary', 'oneOf': [{'minLength': 192, 'maxLength': 192}, {'minLength': 768, 'maxLength': 768}]}, 'application/octet-stream')}
        if path == '/sounds/{name}' and method == 'put':
            params += [parameter('offset', integer(default=0)), parameter('final', dict(enum('0', '1'), default='0'))]
            op['requestBody'] = {'required': False, 'content': content(string(format='binary', maxLength=4096), 'application/octet-stream')}
        if path == '/berry/scripts/{name}':
            if method == 'get': op['responses']['200']['content'] = content(string(maxLength=8000), 'text/plain')
            if method == 'put': op['requestBody'] = {'required': True, 'content': content(string(maxLength=8000), 'text/plain')}
        if path == '/berry/scripts/{name}' and method == 'put':
            op['requestBody']['content']['text/plain']['example'] = 'print(\"hello\")\n'
        if path == '/events':
            op['responses']['200']['content'] = {'text/event-stream': {'schema': string(description='sse data lines contain an applied event json object; no event or id fields; keepalive comments; no replay'), 'example': 'data: {\"revision\":24,\"age_ms\":12,\"cmd\":\"set_base\",\"source\":\"input\",\"base\":\"clock\"}\n\n', 'x-event-schema': ref('AppliedEvent')}}
        if path.startswith('/streams'):
            op['description'] = 'reserved route; stream sessions are unavailable in this release. request body is ignored after authentication.'
            op['x-implemented'] = False
            del op['responses']['200']
            op['responses']['503'] = {'description': 'not_implemented: stream sessions are not available in this release', 'content': {'application/json': {'schema': ref('ErrorResponse'), 'example': {'error': 'not_implemented', 'message': 'stream sessions are not available in this release', 'request_id': '0000000000000000'}}}}
        if params: op['parameters'] = params
        paths.setdefault(path, {})[method] = op
    standalone = {'$schema': DIALECT, '$id': '/api/schema.json', 'title': 'tc002 custom runtime api schemas', 'description': 'request and response model library. select a model by fragment, for example /api/schema.json#/$defs/ConfigBody. the root intentionally accepts any instance; select a model to validate. byte limits, pooled storage, dynamic catalogue values and state-dependent conflicts are checked by the runtime.', '$defs': schemas}
    spec = {'openapi': '3.1.0', 'jsonSchemaDialect': DIALECT, 'info': {'title': 'tc002 custom runtime api', 'version': '1', 'description': 'custom runtime http api, not the stock vendor protocol. bearer authentication is required for every /api/v1 operation. scopes are independent, not hierarchical; x-required-scope names the necessary bit. same-origin requests and configured allowed origins are accepted; a bearer token is still required. the docs and schema endpoints are public and contain no credentials. transport is plaintext on the device. request ids support retries and epoch prevents stale renderer commands.'}, 'servers': [{'url': '/api/v1'}], 'security': [{'bearerAuth': []}], 'paths': paths, 'components': {'securitySchemes': {'bearerAuth': {'type': 'http', 'scheme': 'bearer', 'description': '64 hex character built-in or named client token; send Authorization: Bearer <token>'}}, 'schemas': schemas}}
    # openapi uses components; standalone fragments stay entirely self-contained.
    spec = json.loads(json.dumps(spec).replace('#/$defs/', '#/components/schemas/'))
    return {'openapi.json': spec, 'schema.json': standalone}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if committed artifacts differ from generated output')
    args = parser.parse_args()
    stale = []
    for name, document in build().items():
        path = ROOT / 'src/net/docs' / name
        rendered = json.dumps(document, ensure_ascii=True, separators=(',', ':'), sort_keys=True) + '\n'
        if args.check:
            if not path.exists() or path.read_text() != rendered:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(rendered)
            print('generated ' + str(path.relative_to(ROOT)))
    if stale:
        raise SystemExit('stale api contracts: ' + ', '.join(stale) + '; run python3 tools/generate-api-schema.py')


if __name__ == '__main__':
    main()
