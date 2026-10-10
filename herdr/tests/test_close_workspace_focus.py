import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / "scripts" / "herdr-focus-main-workspace.py"
spec = importlib.util.spec_from_file_location("focus_main_workspace", HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class CloseWorkspaceFocusTests(unittest.TestCase):
    def run_cleanup(self, workspace="source", pane="source:p1", source_pane="source:p1"):
        snapshot = {
            "focused_workspace_id": workspace,
            "focused_pane_id": pane,
            "workspaces": [
                {"workspace_id": "main", "worktree": {"checkout_path": "/repo"}},
            ],
            "panes": [],
        }

        def respond(*args):
            if args == ("api", "snapshot"):
                return {"snapshot": snapshot}
            return {}

        with patch.object(helper, "herdr", side_effect=respond) as api:
            helper.close_and_focus_main("/repo", "source", source_pane)
        return [call.args for call in api.call_args_list]

    def test_original_pane_returns_to_main_after_close(self):
        calls = self.run_cleanup()
        self.assertEqual(calls, [
            ("api", "snapshot"),
            ("workspace", "close", "source"),
            ("api", "snapshot"),
            ("workspace", "focus", "main"),
        ])

    def test_other_workspace_keeps_focus(self):
        calls = self.run_cleanup(workspace="other", pane="other:p1")
        self.assertEqual(calls, [("api", "snapshot"), ("workspace", "close", "source")])

    def test_other_pane_in_same_workspace_does_not_return_to_main(self):
        calls = self.run_cleanup(pane="source:p2")
        self.assertEqual(calls, [("api", "snapshot"), ("workspace", "close", "source")])

    def test_no_focused_pane_does_not_return_to_main(self):
        calls = self.run_cleanup(pane=None)
        self.assertEqual(calls, [("api", "snapshot"), ("workspace", "close", "source")])

    def test_missing_source_pane_closes_without_navigating(self):
        calls = self.run_cleanup(source_pane="")
        self.assertEqual(calls, [("workspace", "close", "source")])

    def test_focus_lookup_failure_still_closes_without_navigating(self):
        with patch.object(helper, "herdr", side_effect=[RuntimeError("offline"), {}]) as api:
            with contextlib.redirect_stderr(io.StringIO()):
                helper.close_and_focus_main("/repo", "source", "source:p1")
        self.assertEqual([call.args for call in api.call_args_list], [
            ("api", "snapshot"), ("workspace", "close", "source"),
        ])

    def test_close_failure_does_not_navigate(self):
        focused = {"snapshot": {"focused_workspace_id": "source", "focused_pane_id": "source:p1"}}
        with patch.object(helper, "herdr", side_effect=[focused, RuntimeError("close failed")]) as api:
            with self.assertRaisesRegex(RuntimeError, "close failed"):
                helper.close_and_focus_main("/repo", "source", "source:p1")
        self.assertEqual([call.args for call in api.call_args_list], [
            ("api", "snapshot"), ("workspace", "close", "source"),
        ])


if __name__ == "__main__":
    unittest.main()
