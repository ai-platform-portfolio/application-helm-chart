"""The deployed-test status must belong to the current same-repository PR head."""

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "files/argocd/report-test-status.py"
spec = importlib.util.spec_from_file_location("report_test_status", SCRIPT)
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)


SHA = "a" * 40
REPO = "example/orders"


def pr(sha=SHA):
    return {"state": "open", "number": 42,
            "head": {"sha": sha, "repo": {"full_name": REPO}},
            "base": {"repo": {"full_name": REPO}}}


class StatusTest(unittest.TestCase):
    def test_current_head_gets_fixed_required_context(self):
        posted = []
        status.report(REPO, "42", SHA, "success", lambda _: pr(), lambda path, body: posted.append((path, body)))
        self.assertEqual(posted[0][0], f"/repos/{REPO}/statuses/{SHA}")
        self.assertEqual(posted[0][1]["context"], "deployed-playwright")
        self.assertEqual(posted[0][1]["state"], "success")

    def test_stale_head_cannot_receive_success(self):
        posted = []
        with self.assertRaisesRegex(ValueError, "PR head is no longer"):
            status.report(REPO, "42", SHA, "success", lambda _: pr("b" * 40),
                          lambda path, body: posted.append((path, body)))
        self.assertFalse(posted)

    def test_failure_overrides_a_prior_success_for_same_head(self):
        posted = []
        status.report(REPO, "42", SHA, "failure", lambda _: pr(), lambda path, body: posted.append(body))
        self.assertEqual(posted[0]["state"], "failure")


if __name__ == "__main__":
    unittest.main()
