"""offline tests for tc002-adopt.py: the lan sweep is opt-in."""
import argparse
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("tc002_adopt", ROOT / "tc002-adopt.py")
adopt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adopt)


class DiscoverSweepTests(unittest.TestCase):
    def args(self, **overrides):
        base = dict(listen=0.01, no_listen=False, sweep=False, subnet="10.0.0")
        base.update(overrides)
        return argparse.Namespace(**base)

    def run_discover(self, args, found_by_sweep=()):
        out = io.StringIO()
        with patch.object(adopt, "listen", return_value={}), \
             patch.object(adopt, "sweep", return_value=list(found_by_sweep)) as sweep, \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = adopt.cmd_discover(args)
        return rc, sweep, out.getvalue()

    def test_nothing_heard_does_not_sweep_the_lan_by_default(self):
        # probing 254 hosts is slow and noisy, and used to happen silently whenever the broadcast
        # listener came up empty. it has to be asked for.
        rc, sweep, out = self.run_discover(self.args())
        sweep.assert_not_called()
        self.assertEqual(rc, 1)
        self.assertIn("--sweep", out)

    def test_sweep_runs_only_when_asked(self):
        rc, sweep, out = self.run_discover(self.args(sweep=True),
                                           found_by_sweep=[("10.0.0.5", {"devSn": "sn", "mac": "m", "appVer": "1", "mcuVer": "2", "ssid": "w"})])
        sweep.assert_called_once_with("10.0.0")
        self.assertEqual(rc, 0)
        self.assertIn("10.0.0.5", out)

    def test_cli_has_sweep_and_no_longer_no_sweep(self):
        seen = {}
        with patch.object(adopt, "cmd_discover", side_effect=lambda a: seen.update(vars(a)) or 0), \
             patch.object(sys, "argv", ["tc002-adopt.py", "discover", "--sweep", "--no-listen"]):
            self.assertEqual(adopt.main(), 0)
        self.assertTrue(seen["sweep"])
        self.assertNotIn("no_sweep", seen)
        with patch.object(sys, "argv", ["tc002-adopt.py", "discover", "--no-sweep"]), \
             contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                adopt.main()


if __name__ == "__main__":
    unittest.main()
