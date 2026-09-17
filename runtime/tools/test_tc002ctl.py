"""notification client wire behaviour; run with /usr/bin/python3 -m unittest."""
import contextlib
import io
import json
import unittest
from unittest.mock import patch

import tc002ctl


class NotificationTests(unittest.TestCase):
    def run_client(self, *arguments, status=200):
        requests = []

        def urlopen(request, timeout):
            requests.append(request)
            if request.method == "POST" and status >= 400:
                raise tc002ctl.urllib.error.HTTPError(request.full_url, status, "rejected", {},
                                                     io.BytesIO(b'{"status":"rejected"}'))
            response = io.BytesIO(b'{"epoch":7}' if request.method == "GET" else b'{"status":"applied"}')
            response.status = status if request.method == "POST" else 200
            return response

        with patch.object(tc002ctl.sys, "argv", ["tc002ctl.py", "-s", "example.invalid", "--token", "test-token", *arguments]), \
                patch.object(tc002ctl.secrets, "token_hex", return_value="0123456789abcdef"), \
                patch.object(tc002ctl.urllib.request, "urlopen", side_effect=urlopen), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            try:
                result = tc002ctl.main()
            except SystemExit as exc:
                self.fail(f"client rejected notification command: {exc}")
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[0].full_url, "http://example.invalid/api/v1/status")
        self.assertEqual(requests[1].method, "POST")
        self.assertEqual(requests[1].get_header("Authorization"), "Bearer test-token")
        return result, requests[1].full_url, json.loads(requests[1].data)

    def test_notify_preserves_default_payload(self):
        result, url, body = self.run_client("notify", "hello", "world")
        self.assertEqual(result, 0)
        self.assertEqual(url, "http://example.invalid/api/v1/notify")
        self.assertEqual(body, {"text": "hello world", "duration_s": 5,
                                "request_id": "0123456789abcdef", "epoch": 7})

    def test_notify_queue_flags_preserve_existing_options(self):
        result, url, body = self.run_client("notify", "doorbell", "--name", "door-1", "--stack", "--hold",
                                           "--colour", "ff0080", "--duration", "12", "--transition", "slide",
                                           "--direction", "left", "--transition-ms", "250", "--exit", "same")
        self.assertEqual(result, 0)
        self.assertEqual(url, "http://example.invalid/api/v1/notify")
        self.assertEqual(body, {"text": "doorbell", "duration_s": 12, "name": "door-1", "stack": True,
                                "hold": True, "colour": "ff0080", "transition": "slide", "direction": "left",
                                "transition_ms": 250, "exit": "same", "request_id": "0123456789abcdef", "epoch": 7})

    def test_notify_flags_are_independent(self):
        for flag, value in [("--name", "door_1"), ("--stack", True), ("--hold", True)]:
            with self.subTest(flag=flag):
                arguments = ["notify", "hello", flag] + ([value] if flag == "--name" else [])
                _, _, body = self.run_client(*arguments)
                self.assertEqual({key: body[key] for key in ("name", "stack", "hold") if key in body},
                                 {flag[2:]: value})

    def test_dismiss_current_omits_name(self):
        result, url, body = self.run_client("dismiss")
        self.assertEqual(result, 0)
        self.assertEqual(url, "http://example.invalid/api/v1/notify/dismiss")
        self.assertEqual(body, {"request_id": "0123456789abcdef", "epoch": 7})

    def test_dismiss_named_notification(self):
        result, url, body = self.run_client("dismiss", "door-1")
        self.assertEqual(result, 0)
        self.assertEqual(url, "http://example.invalid/api/v1/notify/dismiss")
        self.assertEqual(body, {"name": "door-1", "request_id": "0123456789abcdef", "epoch": 7})

    def test_dismiss_explicit_empty_name_is_not_current(self):
        result, _, body = self.run_client("dismiss", "", status=400)
        self.assertEqual(body["name"], "")
        self.assertEqual(result, 1)

    def test_full_queue_returns_failure(self):
        result, _, _ = self.run_client("notify", "hello", "--stack", status=409)
        self.assertEqual(result, 1)


if __name__ == "__main__":
    unittest.main()
