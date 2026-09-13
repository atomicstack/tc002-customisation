"""script editor proxy permissions; run with unittest."""
import unittest
import serve


class ScriptProxyTests(unittest.TestCase):
    def test_script_writes_and_execution_use_admin_authority(self):
        for method, endpoint in [("PUT", "berry/scripts/autoexec"),
                                 ("DELETE", "berry/scripts/hello.be"),
                                 ("POST", "berry/scripts/hello.be/run")]:
            with self.subTest(method=method, endpoint=endpoint):
                self.assertEqual(serve.token_for(method, endpoint), "admin")

    def test_script_reads_keep_control_authority(self):
        for endpoint in ["berry", "berry/scripts", "berry/scripts/hello.be"]:
            self.assertEqual(serve.token_for("GET", endpoint), "control")

    def test_run_path_preserves_script_name(self):
        self.assertEqual(serve.rewrite("/api/127.0.0.1:18080/v1/berry/scripts/hello.be/run"),
                         ("127.0.0.1:18080", "berry/scripts/hello.be/run", ""))

    def test_editor_assets_are_allowed_but_drafts_are_not_files(self):
        for path in ["/scripts-model.js", "/scripts-editor.js", "/scripts-editor.css"]:
            self.assertIn(path, serve.STATIC_ALLOW)
        for path in ["/scripts-drafts.json", "/test_scripts.mjs", "/tokens.json"]:
            self.assertNotIn(path, serve.STATIC_ALLOW)
