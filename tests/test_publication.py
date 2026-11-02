"""Publication policy and real packaged-hook checks; no API writes or credentials."""

from copy import deepcopy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stderr
import urllib.error


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("gate", ROOT / "files/argocd/check-publication.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
SHA = "a" * 40


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.publication = {"repository": "org/app", "workflowRef": "org/app/.github/workflows/publish.yml@refs/pull/42/merge",
                            "runId": "123", "runAttempt": "2"}
        self.run = {"id": 123, "run_attempt": 2, "status": "completed", "conclusion": "success",
                    "path": ".github/workflows/publish.yml", "head_sha": SHA, "head_branch": "feature", "event": "pull_request",
                    "repository": {"full_name": "org/app"}, "head_repository": {"full_name": "org/app"},
                    "pull_requests": [{"number": 42}]}
        self.pr = {"number": 42, "state": "open", "head": {"sha": SHA, "ref": "feature", "repo": {"full_name": "org/app"}},
                   "base": {"repo": {"full_name": "org/app"}}}
        self.paths = []

    def get(self, path):
        self.paths.append(path)
        return self.pr if path.endswith("/pulls/42") else self.run

    def verify(self):
        gate.verify(self.publication, "org/app", ".github/workflows/publish.yml", SHA, "42", self.get)

    def test_exact_attempt_then_current_pr_are_checked(self):
        self.verify()
        self.assertEqual(self.paths, ["/repos/org/app/actions/runs/123/attempts/2", "/repos/org/app/pulls/42"])

    def test_workflow_failure_pending_identity_and_trust_mismatches_block(self):
        original = deepcopy(self.run)
        for change in ({"status": "in_progress"}, {"conclusion": "failure"}, {"conclusion": "cancelled"},
                       {"conclusion": "skipped"}, {"run_attempt": 1}, {"id": 456}, {"head_sha": "b" * 40},
                       {"path": ".github/workflows/other.yml"}, {"event": "push"}, {"pull_requests": [{"number": 43}]},
                       {"head_branch": "other"}, {"head_branch": ""},
                       {"repository": {"full_name": "other/app"}}, {"head_repository": {"full_name": "fork/app"}}):
            with self.subTest(change=change), self.assertRaises(gate.GateError):
                self.run = {**original, **change}
                self.verify()

    def test_empty_github_pr_array_still_requires_matching_live_branch_and_source(self):
        self.run["pull_requests"] = []
        self.verify()
        self.pr["head"]["ref"] = "other"
        with self.assertRaises(gate.GateError):
            self.verify()

    def test_repository_casing_does_not_change_identity(self):
        self.publication.update(repository="Org/App", workflowRef="Org/App/.github/workflows/publish.yml@refs/pull/42/merge")
        self.verify()

    def test_closed_stale_and_fork_prs_block_after_successful_run(self):
        original = deepcopy(self.pr)
        for change in ({"state": "closed"}, {"number": 43}, {"head": {"sha": "b" * 40}},
                       {"head": {"sha": SHA, "repo": {"full_name": "fork/app"}}},
                       {"base": {"repo": {"full_name": "other/app"}}}):
            with self.subTest(change=change), self.assertRaises(gate.GateError):
                self.pr = {**original, **change}
                self.verify()

    def test_untrusted_metadata_is_rejected_before_api_access(self):
        original = deepcopy(self.publication)
        for change in ({"repository": "other/app"}, {"workflowRef": "org/app/.github/workflows/other.yml@refs/pull/42/merge"},
                       {"runId": "../123"}, {"runAttempt": "0"}, {"runAttempt": 2}):
            with self.subTest(change=change), self.assertRaises(gate.GateError):
                self.publication = {**original, **change}
                self.verify()
        self.assertEqual(self.paths, [])

    def test_api_failures_are_redacted_and_fail_closed(self):
        env = {"PUBLICATION": json.dumps(self.publication), "EXPECTED_REPOSITORY": "org/app",
               "EXPECTED_WORKFLOW": ".github/workflows/publish.yml", "EXPECTED_REVISION": SHA, "PR_NUMBER": "42"}
        for error in (urllib.error.HTTPError("url", 403, "secret-value", {}, None),
                      TimeoutError("secret-value"), ValueError("secret-value")):
            with self.subTest(error=type(error).__name__), patch.dict(os.environ, env), \
                    patch.object(gate, "verify", side_effect=error), redirect_stderr(io.StringIO()) as output:
                self.assertEqual(gate.main(), 1)
                self.assertNotIn("secret-value", output.getvalue())

    def test_api_reads_observe_rotated_token_and_have_timeout_and_redirect_protection(self):
        with patch.object(gate.Path, "read_text", side_effect=["first-token", "renewed-token"]), \
                patch.object(gate.urllib.request, "build_opener") as build:
            response = build.return_value.open.return_value.__enter__.return_value
            response.read.return_value = b'{}'
            for token in ("first-token", "renewed-token"):
                self.assertEqual(gate.github_get("/repos/org/app/pulls/42"), {})
                request = build.return_value.open.call_args.args[0]
                self.assertEqual(request.get_header("Authorization"), "Bearer " + token)
                self.assertEqual(build.return_value.open.call_args.kwargs["timeout"], 10)
                self.assertIsInstance(build.call_args.args[0], gate.NoRedirect)
        with self.assertRaises(gate.GateError):
            gate.NoRedirect().redirect_request(None)

    def test_real_package_embeds_bounded_presync_job_and_missing_metadata_fails(self):
        helm = os.environ.get("HELM_BIN", "helm")
        values = {"namespace": "app-pr-42", "platform": {"release": {"expectedRevision": SHA,
                  "check": {"enabled": True, "repository": "org/app", "pullRequest": "42"}}}}
        with tempfile.TemporaryDirectory(prefix="publication-gate-") as directory:
            tmp = Path(directory)
            chart = tmp / "chart"
            shutil.copytree(ROOT, chart, ignore=shutil.ignore_patterns(".git", ".github", "__pycache__"))
            overlay = tmp / "values.json"
            overlay.write_text(json.dumps(values))
            for present in (False, True):
                if present:
                    (chart / "publication.json").write_text(json.dumps(self.publication))
                subprocess.run([helm, "package", str(chart), "--app-version", SHA, "--destination", str(tmp)],
                               check=True, capture_output=True, text=True)
                package = next(tmp.glob("application-*.tgz"))
                result = subprocess.run([helm, "template", "preview", str(package), "-f", str(overlay),
                                         "--show-only", "templates/argocd/publication-check.yaml"], capture_output=True, text=True)
                if not present:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("requires packaged publication.json", result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    for expected in ('namespace: "argocd"', 'argocd.argoproj.io/hook: PreSync', 'backoffLimit: 0',
                                     'activeDeadlineSeconds: 60', 'automountServiceAccountToken: false',
                                     'secretName: "argocd-github-api"', 'readOnlyRootFilesystem: true'):
                        self.assertIn(expected, result.stdout)
                    self.assertNotIn('kind: Role', result.stdout)
                    self.assertIn('def verify(', result.stdout)


if __name__ == "__main__":
    unittest.main()
