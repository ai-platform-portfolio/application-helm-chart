"""Publish one current-PR commit status from an Argo hook."""

import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("GitHub API redirect rejected")


def report(repository, number, revision, state, get, post):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository")
    if not re.fullmatch(r"[1-9][0-9]{0,9}", number):
        raise ValueError("Invalid PR number")
    if not re.fullmatch(r"[a-f0-9]{40}", revision) or state not in ("pending", "success", "failure"):
        raise ValueError("Invalid revision or status")
    pr = get(f"/repos/{repository}/pulls/{number}")
    if (pr.get("state") != "open" or str(pr.get("number")) != number
            or pr.get("head", {}).get("sha") != revision
            or pr.get("head", {}).get("repo", {}).get("full_name", "").lower() != repository.lower()
            or pr.get("base", {}).get("repo", {}).get("full_name", "").lower() != repository.lower()):
        raise ValueError("PR head is no longer the expected same-repository source")
    post(f"/repos/{repository}/statuses/{revision}", {
        "state": state,
        "context": "deployed-playwright",
        "description": {
            "pending": "Waiting for deployed Playwright validation",
            "success": "Deployed Playwright validation passed",
            "failure": "Deployed Playwright validation failed",
        }[state],
    })


def main():
    token = Path("/var/run/github/token").read_text().strip()
    opener = urllib.request.build_opener(NoRedirect())

    def request(path, payload=None):
        body = None if payload is None else json.dumps(payload).encode()
        headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2026-03-10", "User-Agent": "application-test-status"}
        req = urllib.request.Request("https://api.github.com" + path, data=body, headers=headers)
        with opener.open(req, timeout=10) as response:
            result = response.read(2 * 1024 * 1024 + 1)
        if len(result) > 2 * 1024 * 1024:
            raise ValueError("GitHub response too large")
        return json.loads(result)

    report(os.environ["REPOSITORY"], os.environ["PR_NUMBER"], os.environ["REVISION"],
           os.environ["STATUS"], request, request)
    print("Current PR source deployed-test status published")


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        print(f"GitHub test status blocked: {error}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.HTTPError as error:
        print(f"GitHub test status blocked: HTTP {error.code}", file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print(f"GitHub test status blocked: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
