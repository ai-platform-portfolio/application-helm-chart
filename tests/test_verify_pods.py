"""Check that the PostSync gate rejects stale or absent runtime images."""

import importlib.util
from copy import deepcopy
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "files/testworkflows/verify-pods.py"
spec = importlib.util.spec_from_file_location("verify_pods", SCRIPT)
verify_pods = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_pods)


EXPECTED = "registry.example/web@sha256:" + "a" * 64


def pod(image=EXPECTED):
    return {
        "metadata": {"name": "web-1", "labels": {"app.kubernetes.io/component": "web"}},
        "spec": {"containers": [{"name": "web", "image": image}]},
        "status": {
            "phase": "Running",
            "conditions": [{"type": "Ready", "status": "True"}],
            "containerStatuses": [{"name": "web", "ready": True,
                                   "containerID": "containerd://123", "imageID": "registry.example/web@sha256:child"}],
        },
    }


class VerifyPodsTest(unittest.TestCase):
    def test_ready_pod_with_published_digest_passes(self):
        verify_pods.verify([pod()], {"web": EXPECTED})

    def test_stale_pod_blocks_browser_test(self):
        with self.assertRaisesRegex(ValueError, "not ready with the published"):
            verify_pods.verify([pod("registry.example/web@sha256:" + "b" * 64)], {"web": EXPECTED})

    def test_missing_pod_blocks_browser_test(self):
        with self.assertRaisesRegex(ValueError, "No running pod"):
            verify_pods.verify([], {"web": EXPECTED})

    def test_rollout_checks_only_pods_selected_by_stable_service(self):
        current = pod()
        current["metadata"]["labels"]["rollouts-pod-template-hash"] = "new"
        old = deepcopy(current)
        old["metadata"]["name"] = "web-old"
        old["metadata"]["labels"]["rollouts-pod-template-hash"] = "old"
        old["spec"]["containers"][0]["image"] = "registry.example/web@sha256:" + "b" * 64
        rollout = {"metadata": {"name": "web"}, "spec": {"strategy": {"canary": {"stableService": "web"}}},
                   "status": {"stableRS": "new"}}
        service = {"metadata": {"name": "web"}, "spec": {"selector": {"rollouts-pod-template-hash": "new"}}}
        verify_pods.verify([old, current], {"web": EXPECTED}, [rollout], [service])

    def test_rollout_rejects_stable_service_without_hash(self):
        rollout = {"metadata": {"name": "web"}, "spec": {"strategy": {"canary": {"stableService": "web"}}},
                   "status": {"stableRS": "new"}}
        service = {"metadata": {"name": "web"}, "spec": {"selector": {}}}
        with self.assertRaisesRegex(ValueError, "does not select the promoted"):
            verify_pods.verify([pod()], {"web": EXPECTED}, [rollout], [service])


if __name__ == "__main__":
    unittest.main()
