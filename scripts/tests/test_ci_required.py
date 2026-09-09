"""CI must distinguish real evidence from skipped jobs and unrelated trees."""
import importlib.machinery
import importlib.util
import os
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("ci_required", str(Path(__file__).parents[1] / "ci-required"))
spec = importlib.util.spec_from_loader(loader.name, loader)
ci = importlib.util.module_from_spec(spec)
loader.exec_module(ci)


class CIRequiredTests(unittest.TestCase):
    def test_documentation_and_bundled_app_resources(self):
        for workflow in ci.PATTERNS:
            self.assertFalse(ci.affects(workflow, ["README.md", "Sources/WinnowApp/README.md", "docs/index.html"]))
        self.assertTrue(ci.affects("ci", ["docs/vaults.html"]))
        self.assertFalse(ci.affects("node-tests", ["docs/vaults.html"]))

    def test_code_and_selector_changes_require_checks(self):
        for workflow in ci.PATTERNS:
            for path in ["Sources/WalletCore/Wallet.swift", "Tests/Support/Node/CoreSigner.swift",
                         "scripts/ci-required", "scripts/tests/test_ci_required.py", "Package.resolved"]:
                self.assertTrue(ci.affects(workflow, [path]), (workflow, path))

    def evidence(self, *, tree="same", repo="owner/repo", conclusion="success", event="pull_request", skipped=False):
        run = {"id": 42, "head_repository": {"full_name": repo}, "head_commit": {"tree_id": tree},
               "conclusion": conclusion, "event": event, "html_url": "https://github.com/example/run/42"}
        jobs = [{"name": name, "conclusion": "skipped" if skipped else "success"} for name in ci.JOBS["node-tests"]]
        def request(path):
            return {"workflow_runs": [run]} if "/workflows/" in path else {"jobs": jobs}
        return ci.successful_source("node-tests", "owner/repo", "same", request)

    def test_reuses_only_successful_same_repository_tree(self):
        self.assertIsNotNone(self.evidence())
        for change in [{"tree": "different"}, {"repo": "fork/repo"}, {"conclusion": "failure"},
                       {"event": "push"}, {"skipped": True}]:
            self.assertIsNone(self.evidence(**change), change)

    def test_every_required_job_must_pass(self):
        for workflow in ci.JOBS:
            run = {"id": 42, "head_repository": {"full_name": "owner/repo"},
                   "head_commit": {"tree_id": "same"}, "event": "pull_request",
                   "conclusion": "success", "html_url": "run"}
            for omitted in ci.JOBS[workflow]:
                def request(path):
                    return {"workflow_runs": [run]} if "/workflows/" in path else {
                        "jobs": [{"name": name, "conclusion": "success"}
                                 for name in ci.JOBS[workflow] if name != omitted]}
                self.assertIsNone(ci.successful_source(workflow, "owner/repo", "same", request))

    def test_manual_nightly_and_tagged_release_always_run(self):
        with patch.dict(os.environ, {"GITHUB_REF": "refs/tags/v1.0.0"}):
            for event in ["schedule", "workflow_dispatch", "push"]:
                self.assertTrue(ci.required("node-tests", event, {})[0])

    def test_pull_requests_do_not_reuse_other_run_evidence(self):
        with patch.object(ci, "git", return_value="Sources/WalletCore/Wallet.swift"), \
             patch.object(ci, "successful_source", side_effect=AssertionError("must not reuse PR checks")):
            self.assertTrue(ci.required("node-tests", "pull_request", {
                "pull_request": {"base": {"sha": "a" * 40}}})[0])

    def test_api_failure_runs_checks_and_explains_the_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory, "event.json")
            event.write_text(json.dumps({"before": "a" * 40}))
            output, summary = Path(directory, "output"), Path(directory, "summary")
            env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
                   "GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output),
                   "GITHUB_STEP_SUMMARY": str(summary), "GITHUB_REPOSITORY": "owner/repo"}
            with patch.dict(os.environ, env), patch.object(ci.sys, "argv", ["ci-required", "ci"]), \
                 patch.object(ci, "git", return_value="Sources/WalletCore/Wallet.swift"), \
                 patch.object(ci, "successful_source", side_effect=OSError("API unavailable")):
                ci.main()
            self.assertEqual(output.read_text(), "required=true\n")
            self.assertIn("running fresh checks", summary.read_text())

    def test_main_reuses_only_when_evidence_is_available(self):
        with patch.dict(os.environ, {"GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": "owner/repo"}), \
             patch.object(ci, "git", return_value="Sources/WalletCore/Wallet.swift"):
            for evidence, expected in [(None, True), ("https://github.com/example/run/42", False)]:
                with patch.object(ci, "successful_source", return_value=evidence):
                    run, reason = ci.required("ci", "push", {"before": "a" * 40})
                    self.assertEqual(run, expected)
                    if evidence:
                        self.assertIn(evidence, reason)


if __name__ == "__main__":
    unittest.main()
