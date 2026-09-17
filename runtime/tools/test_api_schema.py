#!/usr/bin/env python3
"""verify contracts against the runtime; test dependencies: jsonschema, openapi-spec-validator."""
import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / 'src/net/docs'

class ApiContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = (ROOT / 'src/net/api.zig').read_text()

    def artifacts(self):
        self.assertTrue((DOCS / 'openapi.json').is_file(), 'the openapi contract is missing')
        self.assertTrue((DOCS / 'schema.json').is_file(), 'the standalone schema is missing')
        return json.loads((DOCS / 'openapi.json').read_text()), json.loads((DOCS / 'schema.json').read_text())

    def test_every_static_and_dynamic_route_and_scope(self):
        spec, _ = self.artifacts()
        expected = {(path.removeprefix('/api/v1'), method.lower()): scope for method, path, scope in re.findall(r'\.method = \.(\w+), \.path = "([^"]+)", \.scope = \.(\w+)', self.api)}
        actual = {(path, method): operation['x-required-scope'] for path, item in spec['paths'].items() for method, operation in item.items()}
        self.assertEqual(actual, expected)
        self.assertEqual(spec['openapi'], '3.1.0')
        self.assertEqual(spec['security'], [{'bearerAuth': []}])
        ids = [operation['operationId'] for item in spec['paths'].values() for operation in item.values()]
        self.assertEqual(len(ids), len(set(ids)))
        for path, item in spec['paths'].items():
            for operation in item.values():
                if path.startswith('/streams'):
                    self.assertFalse(operation['x-implemented'])
                    self.assertNotIn('200', operation['responses'])
                    self.assertIn('503', operation['responses'])

    def test_all_wire_request_struct_fields_are_published(self):
        _, standalone = self.artifacts()
        wire = self.api.split('// json wire schemas (request bodies)', 1)[1].split('fn bad(', 1)[0]
        for name, body in re.findall(r'const (\w+Body) = struct \{(.*?)\};', wire, re.S):
            body = re.sub(r'//[^\n]*', '', body)
            fields = set(re.findall(r'(?:@"([^"]+)"|(\w+))\s*:', body))
            fields = {quoted or plain for quoted, plain in fields}
            self.assertIn(name, standalone['$defs'])
            self.assertEqual(set(standalone['$defs'][name]['properties']), fields, name)
            self.assertFalse(standalone['$defs'][name]['additionalProperties'])

    def test_references_and_schema_dialect(self):
        spec, standalone = self.artifacts()
        self.assertEqual(standalone['$schema'], 'https://json-schema.org/draft/2020-12/schema')
        def walk(value, root):
            if isinstance(value, dict):
                if '$ref' in value:
                    self.assertTrue(value['$ref'].startswith('#/'))
                    target = root
                    for part in value['$ref'][2:].split('/'):
                        target = target[part]
                for child in value.values():
                    walk(child, root)
            elif isinstance(value, list):
                for child in value:
                    walk(child, root)
        walk(spec, spec)
        walk(standalone, standalone)

    def test_request_examples_and_invalid_inputs(self):
        from jsonschema import Draft202012Validator
        _, document = self.artifacts()
        Draft202012Validator.check_schema(document)
        cases = [
            ('SceneBody', {'base': 'clock'}, {'base': 'bogus'}),
            ('ActionBody', {'action': 'power', 'power': False}, {'action': 'power'}),
            ('InputBody', {'control': 'rotary', 'event': 'cw', 'steps': 3}, {'control': 'left', 'event': 'cw'}),
            ('NotifyBody', {'text': 'hello', 'colour': 'ff0088'}, {'text': 'hello', 'duration_s': 301}),
            ('ConfigBody', {'discovery_controls': True}, {'brightness': 101}),
            ('ConfigBody', {'latitude': 52.1, 'longitude': 4.3}, {'latitude': 52.1}),
            ('MqttBody', {'host': '192.168.1.2'}, {'port': 0}),
            ('MqttBody', {'host': '192.168.001.002'}, {'host': '999.168.1.2'}),
            ('NtfyBody', {'topic': 'panel'}, {'topic': 'bad/topic'}),
            ('TokensBody', {'name': 'ha', 'scopes': ['display']}, {'name': 'ha', 'scopes': ['tokens']}),
            ('SoundBody', {'stop': True}, {}),
            ('CanvasBody', {'elements': [{'type': 'pixel', 'at': [1, 2]}]}, {'elements': [{'type': 'rect', 'text': 'ignored?'}]}),
            ('CanvasBody', {'elements': [{'type': 'sparkline', 'data': [1, 2, 3]}]}, {'elements': [{'type': 'sparkline', 'data': '1,2,3'}]}),
            ('PatchBody', {'values': [{'id': 'temp', 'text': '22c'}]}, {'values': [{'id': 'temp'}]}),
        ]
        for name, valid, invalid in cases:
            self.assertTrue(name in document['$defs'], 'missing model: ' + name)
            validator = Draft202012Validator({'$ref': '#/$defs/' + name, '$defs': document['$defs']})
            self.assertEqual(list(validator.iter_errors(valid)), [], (name, valid))
            self.assertTrue(list(validator.iter_errors(invalid)), (name, invalid))
        validator = Draft202012Validator({'$ref': '#/$defs/ConfigBody', '$defs': document['$defs']})
        self.assertTrue(list(validator.iter_errors({'unknown_setting': True})))

    def test_response_models_and_discovery(self):
        spec, schema = self.artifacts()
        defs = schema['$defs']
        self.assertEqual(defs['ConfigResponse']['properties']['discovery']['properties']['controls']['default'], False)
        self.assertIn('rgb_base64', defs['ScreenResponse']['properties'])
        self.assertIn('error', defs['ErrorResponse']['properties'])
        self.assertIn('text/event-stream', spec['paths']['/events']['get']['responses']['200']['content'])
        self.assertIn('application/octet-stream', spec['paths']['/screen']['get']['responses']['200']['content'])
        self.assertEqual(spec['paths']['/frame']['post']['requestBody']['content']['application/octet-stream']['schema']['minLength'], 2496)

    def test_documented_request_examples_are_valid(self):
        from jsonschema import Draft202012Validator
        spec, _ = self.artifacts()
        for item in spec['paths'].values():
            for method, operation in item.items():
                self.assertFalse(operation['summary'].startswith(method + ' /'), operation['summary'])
                media = operation.get('requestBody', {}).get('content', {}).get('application/json')
                if media:
                    self.assertIn('example', media)
                    validator = Draft202012Validator(dict(media['schema'], components=spec['components']))
                    self.assertEqual(list(validator.iter_errors(media['example'])), [], operation['operationId'])

    def test_openapi_is_valid(self):
        from openapi_spec_validator import validate
        spec, _ = self.artifacts()
        validate(spec)

    def test_sse_contract_matches_wire(self):
        spec, document = self.artifacts()
        self.assertTrue('AppliedEvent' in document['$defs'], 'missing applied event model')
        event = document['$defs']['AppliedEvent']
        self.assertEqual(set(event['required']), {'revision', 'age_ms', 'cmd', 'source'})
        wire = (ROOT / 'src/net/sse.zig').read_text()
        self.assertNotIn('event:', wire.split('pub fn event(', 1)[1].split('const testing', 1)[0])
        stream = spec['paths']['/events']['get']['responses']['200']['content']['text/event-stream']
        self.assertEqual(stream['example'], 'data: {"revision":24,"age_ms":12,"cmd":"set_base","source":"input","base":"clock"}\n\n')

    def test_response_examples_validate(self):
        from jsonschema import Draft202012Validator
        _, document = self.artifacts()
        examples = {
            'ErrorResponse': {'error': 'unauthorized', 'message': 'a valid bearer token is required', 'request_id': '0000000000000000'},
            'AppliedResponse': {'status': 'applied', 'revision': 3, 'epoch': 1, 'request_id': '0000000000000012'},
            'SavedResponse': {'status': 'saved', 'saved_revision': 3},
            'BerryResult': {'status': 'ok', 'name': 'autoexec'},
            'SoundResult': {'status': 'ok', 'used': 32, 'budget': 262144},
            'LogsResponse': {'next': 2, 'lines': [{'seq': 1, 'text': 'boot'}]},
            'SpritesResponse': {'slots': 8, 'sprites': [{'id': 'weather', 'width': 8, 'height': 8}]},
            'CanvasResponse': {'revision': 1, 'saved_revision': 0, 'age_ms': 1, 'elements': [{'type': 'pixel', 'at': [0, 0], 'colour': 'ffffff', 'age_ms': 1}], 'limits': {'elements': 24, 'text_bytes': 256, 'data_bytes': 1024, 'samples': 52}},
            'ScreenResponse': {'width': 52, 'height': 16, 'epoch': 1, 'revision': 3, 'brightness': 50, 'power': True, 'rgb_base64': 'A' * 3328},
            'TokenResponse': {'name': 'ha', 'scopes': ['display', 'status'], 'token': 'a' * 64},
            'AppliedEvent': {'revision': 24, 'age_ms': 12, 'cmd': 'set_base', 'source': 'input', 'base': 'clock'},
        }
        for name, example in examples.items():
            self.assertTrue(name in document['$defs'], 'missing model: ' + name)
            validator = Draft202012Validator({'$ref': '#/$defs/' + name, '$defs': document['$defs']})
            self.assertEqual(list(validator.iter_errors(example)), [], name)
            broken = dict(example)
            del broken[next(iter(broken))]
            self.assertTrue(list(validator.iter_errors(broken)), name)

    def test_config_documents_immediate_persistence(self):
        spec, _ = self.artifacts()
        description = spec['paths']['/config']['patch']['description']
        self.assertNotIn('until /config/save', description)
        self.assertIn('saved_revision', description)
        self.assertIn('immediately', description)

    def test_generated_artifacts_are_current(self):
        self.artifacts()
        result = subprocess.run([sys.executable, str(ROOT / 'tools/generate-api-schema.py'), '--check'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == '__main__':
    unittest.main()
