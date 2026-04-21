#!/usr/bin/env python3
"""
Create two GitHub repositories for a Unity iOS/App Store workflow:
  1) Main repo — push the local Unity project (no auto_init, you push first commit).
  2) <name>Cert — empty repo with README (match / certificates storage).

Requires: git on PATH, GitHub personal access token with repo scope (classic) or
equivalent fine-grained permissions for repository creation and contents.

HTTPS push: configure credentials (e.g. `gh auth login` then `gh auth setup-git`, or a credential helper).

Usage:
  set GITHUB_TOKEN=ghp_...
  python scripts/bootstrap_github_repos.py --project "C:\\Path\\To\\MyGame"

Optional:
  --owner YOUR_USER_OR_ORG   (default: account that owns the token)
  --cert-suffix Cert         (default: Cert → repo MyGameCert)
  --dry-run                  print actions only
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path


def api_request(method: str, url: str, token: str, data: dict | None = None) -> tuple[int, dict | list | None]:
    body = None if data is None else json.dumps(data).encode("utf-8")
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8")
            if not raw:
                return resp.status, None
            return resp.status, json.loads(raw)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(err_body) if err_body else None
        except json.JSONDecodeError:
            parsed = {"message": err_body or str(e)}
        return e.code, parsed


def slug_repo_name(folder_name: str) -> str:
    s = folder_name.strip().replace(" ", "-")
    s = re.sub(r"[^A-Za-z0-9._-]", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    return s or "unity-project"


def run_git(cwd: Path, args: list[str], dry_run: bool) -> int:
    if dry_run:
        print(f"[dry-run] git -C {cwd} {' '.join(args)}")
        return 0
    r = subprocess.run(["git", "-C", str(cwd), *args])
    return r.returncode


def is_repo_name_taken(body: object) -> bool:
    if not isinstance(body, dict):
        return "already exists" in str(body).lower()
    for err in body.get("errors") or []:
        if isinstance(err, dict):
            msg = (err.get("message") or "").lower()
            if "already exists" in msg:
                return True
    return "already exists" in json.dumps(body).lower()


def main() -> int:
    p = argparse.ArgumentParser(description="Create main + Cert GitHub repos and push Unity project.")
    p.add_argument("--project", required=True, type=Path, help="Path to Unity project root")
    p.add_argument("--owner", default="", help="GitHub user or org (default: token owner)")
    p.add_argument("--cert-suffix", default="Cert", help="Suffix for certificates repo name")
    p.add_argument("--public-repos", action="store_true", help="Create public repos (default is private)")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    project: Path = args.project.resolve()
    if not project.is_dir():
        print(f"Not a directory: {project}", file=sys.stderr)
        return 1

    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token and not args.dry_run:
        print("Set GITHUB_TOKEN (classic PAT with repo, or fine-grained with repo create + contents).", file=sys.stderr)
        return 1

    base_name = slug_repo_name(project.name)
    cert_name = f"{base_name}{args.cert_suffix}"
    visibility_private = not args.public_repos

    api_base = "https://api.github.com"
    token_login = ""
    if not args.dry_run:
        code, user = api_request("GET", f"{api_base}/user", token)
        if code != 200 or not isinstance(user, dict):
            print(f"Could not resolve token user: {user}", file=sys.stderr)
            return 1
        token_login = (user.get("login") or "").strip()
        if not token_login:
            print("Empty login from GitHub API.", file=sys.stderr)
            return 1

    owner = (args.owner.strip() or token_login or "<your-github-login>").strip()

    def create_repo(name: str, auto_init: bool) -> tuple[bool, str]:
        if args.dry_run:
            print(f"[dry-run] create repo {owner}/{name} auto_init={auto_init}")
            return True, f"https://github.com/{owner}/{name}.git"

        payload = {"name": name, "private": visibility_private, "auto_init": auto_init}
        if args.owner and args.owner.strip().lower() != token_login.lower():
            url = f"{api_base}/orgs/{owner}/repos"
            code, body = api_request("POST", url, token, payload)
        else:
            url = f"{api_base}/user/repos"
            code, body = api_request("POST", url, token, payload)

        if code == 201 and isinstance(body, dict):
            return True, body.get("clone_url") or f"https://github.com/{owner}/{name}.git"
        if code == 422 and is_repo_name_taken(body):
            print(f"Repo {owner}/{name} already exists; continuing.", file=sys.stderr)
            return True, f"https://github.com/{owner}/{name}.git"
        print(f"Create {name} HTTP {code}: {body}", file=sys.stderr)
        return False, ""

    ok_main, main_url = create_repo(base_name, auto_init=False)
    if not ok_main:
        return 1
    ok_cert, cert_url = create_repo(cert_name, auto_init=True)
    if not ok_cert:
        return 1

    if not (project / ".git").exists():
        if run_git(project, ["init", "-b", "main"], args.dry_run):
            return 1

    if not args.dry_run:
        subprocess.run(["git", "-C", str(project), "remote", "remove", "origin"], capture_output=True)
    else:
        run_git(project, ["remote", "remove", "origin"], True)

    if args.dry_run:
        print(f"[dry-run] git remote add origin {main_url}")
    else:
        if subprocess.run(["git", "-C", str(project), "remote", "add", "origin", main_url]).returncode != 0:
            return 1

    if not args.dry_run:
        subprocess.run(["git", "-C", str(project), "add", "-A"], check=True)
        st = subprocess.run(
            ["git", "-C", str(project), "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=True,
        )
        if st.stdout.strip():
            subprocess.run(["git", "-C", str(project), "commit", "-m", "Initial commit"], check=True)
        # Push may require auth: gh auth setup-git, or PAT via credential manager
        if subprocess.run(["git", "-C", str(project), "push", "-u", "origin", "main"]).returncode != 0:
            print(
                "git push failed. Configure HTTPS auth (e.g. `gh auth login` + `gh auth setup-git`) "
                "or push manually.",
                file=sys.stderr,
            )
            return 1

    print()
    print("Done.")
    print(f"  Main project:  {main_url}")
    print(f"  Match / certs: {cert_url}")
    print()
    print("Next: add GitHub Actions secrets (repo: Settings - Secrets and variables - Actions).")
    print("  Secrets: UNITY_LICENSE, UNITY_EMAIL, UNITY_PASSWORD, GH_PAT, APPSTORE_KEY_ID,")
    print("           APPSTORE_ISSUER_ID, APPSTORE_P8, MATCH_PASSWORD")
    print("  Variables: GH_USERNAME, BUNDLE_IDENTIFIER, MATCH_GIT_URL, APPLE_TEAM_ID, UNITY_VERSION, ...")
    print()
    print(f"Set MATCH_GIT_URL to the Cert repo (e.g. {cert_url}).")
    print("Then: Actions - unity-build-and-ios-upload - Run workflow")
    return 0


if __name__ == "__main__":
    sys.exit(main())
