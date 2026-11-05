#!/usr/bin/env python3
"""Tests for the deploy pipeline: .github/scripts/deploy-outpost.sh and the workflow.

No AWS, no network, no docker. The remote script is generated with DRY_RUN=1 and then
run against test doubles for docker, aws, flock and sleep (scripts/stubs).

Run: python3 scripts/test_deploy_pipeline.py
Set FORUM_ROOT to run the same tests against another checkout of the repo.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("FORUM_ROOT", HERE.parent)).resolve()
STUBS = HERE / "stubs"
DEPLOY = ROOT / ".github/scripts/deploy-outpost.sh"
WORKFLOW = ROOT / ".github/workflows/deploy-aws.yml"

SHA_A = "a" * 40
SHA_B = "b" * 40
SHA_C = "c" * 40
IMAGE = "society-forum:prod"


def base_env(**extra):
    env = {
        "PATH": os.environ["PATH"],
        "HOME": os.environ.get("HOME", "/"),
        "IMAGE": IMAGE,
        "SERVICE": "prod-forum",
        "GITHUB_SHA": SHA_A,
        "GITHUB_REPOSITORY": "SocietyProtocol/forum",
        "GITHUB_RUN_ID": "1001",
        "BUILD_ARGS": "--build-arg SIWE_BRANCH=main",
        "PIN_REPO_URL": "https://example.invalid/plugin.git",
        "PIN_BRANCH": "main",
        "PIN_BUILD_ARG": "SIWE_REF",
        "PIN_SHA": SHA_B,
        "HEALTH_URL_PATH": "/srv/status",
        "HEALTH_EXPECT_BODY": "ok",
        "HEALTH_PLUGIN_DIR": "/var/www/discourse/plugins/discourse-siwe-auth",
        "HEALTH_TIMEOUT_SECONDS": "1",
        "DRY_RUN": "1",
    }
    env.update(extra)
    return env


def dry_run(env, cwd=None):
    """Run deploy-outpost.sh with DRY_RUN=1; return (returncode, stdout, stderr)."""
    p = subprocess.run(
        ["bash", str(DEPLOY)], env=env, cwd=cwd, capture_output=True, text=True
    )
    return p.returncode, p.stdout, p.stderr


def remote_script(env, cwd=None):
    rc, out, err = dry_run(env, cwd)
    assert rc == 0, "dry run failed: %s" % err
    return out.split("--- DRY_RUN: remote script follows, nothing uploaded ---\n", 1)[1]


class Box:
    """A scratch 'box': stub docker state, a lock file, a compose dir and a /tmp."""

    def __init__(self):
        self.dir = Path(tempfile.mkdtemp(prefix="deploytest."))
        self.state = self.dir / "state"
        self.state.mkdir()
        (self.dir / "compose").mkdir()
        (self.dir / "tmp").mkdir()
        ctx = self.dir / "ctx"
        ctx.mkdir()
        (ctx / "Dockerfile").write_text("FROM scratch\n")
        subprocess.run(
            ["tar", "-czf", str(self.dir / "src.tgz"), "-C", str(ctx), "."], check=True
        )

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    @property
    def lock(self):
        return self.dir / "lock"

    @property
    def tmp(self):
        return self.dir / "tmp"

    @property
    def calls(self):
        p = self.state / "calls.log"
        return p.read_text().splitlines() if p.exists() else []

    def seed(self, tags, running=""):
        import json

        (self.state / "state.json").write_text(
            json.dumps({"tags": tags, "order": list(tags), "running": running})
        )

    def tags(self):
        import json

        return json.loads((self.state / "state.json").read_text())["tags"]

    def deploy(self, use_stub_flock=True, extra_env=None, run_extra=None, timeout=60):
        """Generate the remote script for this box and run it against the stubs."""
        env = base_env(
            LOCK_FILE=str(self.lock),
            LOCK_TIMEOUT_SECONDS="1",
            COMPOSE_DIR=str(self.dir / "compose"),
            REMOTE_TMP=str(self.tmp),
        )
        env.update(extra_env or {})
        script = self.dir / "remote.sh"
        script.write_text(remote_script(env))
        run_env = {
            "PATH": (str(STUBS) + os.pathsep if use_stub_flock else str(self.dir / "nolock") + os.pathsep)
            + os.environ["PATH"],
            "HOME": os.environ.get("HOME", "/"),
            "STUB_STATE": str(self.state),
            "STUB_TGZ": str(self.dir / "src.tgz"),
            "STUB_IMAGE": env["IMAGE"],
            "STUB_PLUGIN_SHA": env.get("PIN_SHA", ""),
        }
        run_env.update(run_extra or {})
        if not use_stub_flock:
            # keep stubs for everything except flock: real flock must come first or be absent
            d = self.dir / "nolock"
            d.mkdir(exist_ok=True)
            for name in ("docker", "aws", "sleep"):
                (d / name).symlink_to(STUBS / name)
        p = subprocess.run(
            ["bash", str(script)], env=run_env, capture_output=True, text=True, timeout=timeout
        )
        return p


class BoxTestCase(unittest.TestCase):
    def setUp(self):
        self.box = Box()
        self.addCleanup(self.box.cleanup)


class ConcurrencyTests(BoxTestCase):
    def test_workflow_deploy_jobs_share_one_concurrency_group(self):
        text = WORKFLOW.read_text()
        groups = re.findall(r"^\s+group:\s*(\S+)\s*$", text, re.M)
        self.assertEqual(groups, ["aws-outpost-forum", "aws-outpost-forum"], groups)
        cancels = re.findall(r"^\s+cancel-in-progress:\s*(\S+)\s*$", text, re.M)
        self.assertEqual(cancels, ["false", "false"])

    def test_remote_script_uses_no_fixed_tmp_paths(self):
        script = remote_script(base_env())
        for fixed in ("/tmp/society-src", "/tmp/society-deploy.sh"):
            self.assertNotIn(fixed, script)
        self.assertIn("mktemp -d", script)

    def test_ssm_command_uses_a_private_directory(self):
        # The SSM command string is built in python inside the script; check its source.
        text = DEPLOY.read_text()
        self.assertNotIn("/tmp/society-deploy.sh", text)
        self.assertIn("mktemp -d /tmp/society-deploy.XXXXXX", text)

    def test_s3_prefix_is_unique_per_run(self):
        a = remote_script(base_env(GITHUB_RUN_ID="1"))
        b = remote_script(base_env(GITHUB_RUN_ID="2"))
        pa = re.search(r"export PREFIX=(\S+)", a).group(1)
        pb = re.search(r"export PREFIX=(\S+)", b).group(1)
        self.assertNotEqual(pa, pb)

    def test_lock_is_taken_before_any_docker_command_and_dir_is_cleaned(self):
        p = self.box.deploy()
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        calls = self.box.calls
        flock_at = next(i for i, c in enumerate(calls) if c.startswith("flock "))
        first_docker = next(i for i, c in enumerate(calls) if c.startswith("docker "))
        self.assertLess(flock_at, first_docker)
        self.assertEqual(list(self.box.tmp.iterdir()), [], "run dir left behind")

    def test_deploy_fails_without_touching_docker_when_the_lock_is_held(self):
        import fcntl

        with open(self.box.lock, "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            p = self.box.deploy()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("another deploy held", p.stderr)
        self.assertEqual([c for c in self.box.calls if c.startswith("docker ")], [])

    @unittest.skipUnless(shutil.which("flock"), "util-linux flock not installed")
    def test_real_flock_blocks_a_second_deploy(self):
        import fcntl

        with open(self.box.lock, "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            p = self.box.deploy(use_stub_flock=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual([c for c in self.box.calls if c.startswith("docker ")], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
