"""the demo helper's request wrappers: which token each route is sent with.

  python3 -I -m unittest discover -s runtime/tools -p test_tc002demo.py
"""
import os, sys, unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002demo  # noqa: e402


class SpriteTokenTests(unittest.TestCase):
    def device(self):
        with mock.patch.object(tc002demo.tc002ctl, "load_token", side_effect=lambda args, admin: "A" if admin else "C"):
            return tc002demo.Device(object(), "test")

    def test_a_sprite_is_deleted_with_the_token_that_uploaded_it(self):
        # uploading needs the content scope, which only the admin token holds; deleting needs the
        # same scope, so a delete sent with the control token was refused with a 403
        dev = self.device()
        sent = []
        def call(args, method, path, body, token=None, **kw):
            sent.append((method, path, token))
            return 200, b"{}"
        with mock.patch.object(tc002demo.tc002ctl, "call", side_effect=call):
            dev.put_sprite("ring", bytes(3))
            dev.delete_sprite("ring")
        self.assertEqual(sent, [("PUT", "/sprites/ring", "A"), ("DELETE", "/sprites/ring", "A")])


if __name__ == "__main__":
    unittest.main()
