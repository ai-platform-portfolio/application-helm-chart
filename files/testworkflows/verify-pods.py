"""Fail closed unless every current application pod runs its published image."""

import json
import os
from pathlib import Path
import ssl
import sys
import urllib.parse
import urllib.request


def verify(pods, expected):
    seen = {component: 0 for component in expected}
    for pod in pods:
        metadata = pod.get("metadata", {})
        if metadata.get("deletionTimestamp"):
            continue
        component = metadata.get("labels", {}).get("app.kubernetes.io/component")
        if component not in expected:
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
    url = f"https://kubernetes.default.svc/api/v1/namespaces/{namespace}/pods?labelSelector={selector}"
    token = Path("/var/run/kubernetes/token").read_text().strip()
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    context = ssl.create_default_context(cafile="/var/run/kubernetes/ca.crt")
    with urllib.request.urlopen(request, context=context, timeout=10) as response:
        body = response.read(2 * 1024 * 1024 + 1)
    if len(body) > 2 * 1024 * 1024:
        raise ValueError("Pod list response is too large")
    result = json.loads(body)
    if result.get("metadata", {}).get("continue"):
        raise ValueError("Pod list is incomplete")
    verify(result.get("items", []), expected)
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
