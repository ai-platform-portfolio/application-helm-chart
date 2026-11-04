"""Fail closed unless every current application pod runs its published image."""

import json
import os
from pathlib import Path
import ssl
import sys
import urllib.parse
import urllib.request


def verify(pods, expected, rollouts=None, services=None):
    rollouts = {item["metadata"]["name"]: item for item in (rollouts or [])}
    services = {item["metadata"]["name"]: item for item in (services or [])}
    seen = {component: 0 for component in expected}
    for pod in pods:
        metadata = pod.get("metadata", {})
        if metadata.get("deletionTimestamp"):
            continue
        component = metadata.get("labels", {}).get("app.kubernetes.io/component")
        if component not in expected:
            continue
        rollout = rollouts.get(component)
        if rollout:
            stable_hash = rollout.get("status", {}).get("stableRS")
            stable_name = rollout["spec"]["strategy"]["canary"]["stableService"]
            selector = services.get(stable_name, {}).get("spec", {}).get("selector", {})
            if not stable_hash or selector.get("rollouts-pod-template-hash") != stable_hash:
                raise ValueError(f"Stable Service {stable_name} does not select the promoted {component} ReplicaSet")
            if any(metadata.get("labels", {}).get(key) != value for key, value in selector.items()):
                continue
        name = metadata.get("name", "unknown")
        containers = {item["name"]: item for item in pod.get("spec", {}).get("containers", [])}
        statuses = {item["name"]: item for item in pod.get("status", {}).get("containerStatuses", [])}
        container = containers.get(component, {})
        status = statuses.get(component, {})
        if (pod.get("status", {}).get("phase") != "Running"
                or not pod.get("status", {}).get("conditions")
                or not any(item.get("type") == "Ready" and item.get("status") == "True"
                           for item in pod["status"]["conditions"])
                or container.get("image") != expected[component]
                or not status.get("ready") or not status.get("containerID") or not status.get("imageID")):
            raise ValueError(f"Pod {name} is not ready with the published {component} image")
        seen[component] += 1
    missing = [component for component, count in seen.items() if count == 0]
    if missing:
        raise ValueError("No running pod for component: " + ", ".join(sorted(missing)))


def main():
    expected = json.loads(os.environ["EXPECTED_IMAGES"])
    selector = urllib.parse.quote("app.kubernetes.io/instance=" + os.environ["INSTANCE"], safe="")
    namespace = urllib.parse.quote(os.environ["NAMESPACE"], safe="")
    token = Path("/var/run/kubernetes/token").read_text().strip()
    context = ssl.create_default_context(cafile="/var/run/kubernetes/ca.crt")

    def list_resources(api_path, kind):
        url = f"https://kubernetes.default.svc/{api_path}/namespaces/{namespace}/{kind}?labelSelector={selector}"
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(request, context=context, timeout=10) as response:
            body = response.read(2 * 1024 * 1024 + 1)
        if len(body) > 2 * 1024 * 1024:
            raise ValueError("Resource list response is too large")
        result = json.loads(body)
        if result.get("metadata", {}).get("continue"):
            raise ValueError("Resource list is incomplete")
        return result.get("items", [])

    pods = list_resources("api/v1", "pods")
    services = list_resources("api/v1", "services")
    rollouts = list_resources("apis/argoproj.io/v1alpha1", "rollouts")
    verify(pods, expected, rollouts, services)
    print("Ready pods use the digest-pinned images from this release")


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        print(f"Deployed image verification failed: {error}", file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print(f"Deployed image verification failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
