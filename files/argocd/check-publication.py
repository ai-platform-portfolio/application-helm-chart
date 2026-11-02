"""One bounded read-only check; native Argo retries own pending/error recovery."""

import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request


class GateError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise GateError(message)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise GateError("GitHub API redirect rejected")


def github_get(path):
    # Read the projected file per request so ESO token renewal is observed.
    token = Path("/var/run/github/token").read_text().strip()
    request = urllib.request.Request("https://api.github.com" + path, headers={
        "Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2026-03-10", "User-Agent": "application-publication-gate",
    })
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=10) as response:
        payload = response.read(2 * 1024 * 1024 + 1)
        require(len(payload) <= 2 * 1024 * 1024, "GitHub API response too large")
        return json.loads(payload)


def verify(publication, repository, workflow, revision, number, get=github_get):
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "Invalid repository")
    require(re.fullmatch(r"\.github/workflows/[^/@]+\.ya?ml", workflow), "Invalid workflow")
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "Invalid expected source")
    require(re.fullmatch(r"[1-9][0-9]{0,9}", number), "Invalid PR number")
    run_id, attempt = publication.get("runId", ""), publication.get("runAttempt", "")
    require(isinstance(run_id, str) and re.fullmatch(r"[1-9][0-9]*", run_id), "Invalid run ID")
    require(isinstance(attempt, str) and re.fullmatch(r"[1-9][0-9]*", attempt), "Invalid run attempt")
    published_repository = publication.get("repository", "")
    require(isinstance(published_repository, str) and published_repository.lower() == repository.lower(),
            "Publication repository mismatch")
    require(publication.get("workflowRef") == f"{published_repository}/{workflow}@refs/pull/{number}/merge",
            "Publication workflow reference mismatch")
    run = get(f"/repos/{repository}/actions/runs/{run_id}/attempts/{attempt}")
    require(str(run.get("id")) == run_id and str(run.get("run_attempt")) == attempt,
            "Workflow run or attempt mismatch")
    require(run.get("status") == "completed" and run.get("conclusion") == "success",
            "Publication workflow has not completed successfully")
    require(run.get("path") == workflow and run.get("head_sha") == revision,
            "Workflow path or source mismatch")
    require(run.get("event") == "pull_request", "Workflow was not a PR publication")
    require(run.get("repository", {}).get("full_name", "").lower() == repository.lower()
            and run.get("head_repository", {}).get("full_name", "").lower() == repository.lower(),
            "Workflow repository mismatch or fork")
    require(not run.get("pull_requests") or any(str(pr.get("number")) == number for pr in run["pull_requests"]),
            "Workflow does not belong to this PR")
    # Final API read: reject a close or push that happened while checking the run.
    pr = get(f"/repos/{repository}/pulls/{number}")
    require(pr.get("state") == "open" and str(pr.get("number")) == number, "PR is no longer open")
    require(pr.get("head", {}).get("sha") == revision, "PR head has advanced")
    # GitHub can return an empty run.pull_requests; bind to the live branch too.
    require(run.get("head_branch") and run["head_branch"] == pr.get("head", {}).get("ref"),
            "Workflow branch does not match the PR")
    require(pr.get("head", {}).get("repo", {}).get("full_name", "").lower() == repository.lower()
            and pr.get("base", {}).get("repo", {}).get("full_name", "").lower() == repository.lower(),
            "PR repository mismatch or fork")


def main():
    try:
        verify(json.loads(os.environ["PUBLICATION"]), os.environ["EXPECTED_REPOSITORY"],
               os.environ["EXPECTED_WORKFLOW"], os.environ["EXPECTED_REVISION"], os.environ["PR_NUMBER"])
    except GateError as error:
        print(f"Publication gate blocked: {error}", file=sys.stderr)
        return 1
    except urllib.error.HTTPError as error:
        print(f"Publication gate blocked: GitHub API HTTP {error.code}", file=sys.stderr)
        return 1
    except Exception as error:
        # Never print response bodies, headers, tokens or exception payloads.
        print(f"Publication gate blocked: {type(error).__name__}", file=sys.stderr)
        return 1
    print("Publication workflow and current PR source verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
