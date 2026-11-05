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
PREPARE = ROOT / ".github/scripts/prepare-target.sh"
DOCKERFILE = ROOT / "Dockerfile"
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


# Values a caller could smuggle in through workflow_dispatch / repository_dispatch.
BAD_SHAS = {
    "newline injection": SHA_A + "\ntarget=prod",
    "newline then checkout_ref": SHA_A + "\ncheckout_ref=evil",
    "trailing newline": SHA_A + "\n",
    "leading newline": "\n" + SHA_A,
    "only a newline": "\n",
    "two valid lines": SHA_A + "\n" + SHA_B,
    "short (39)": "a" * 39,
    "long (41)": "a" * 41,
    "uppercase": "A" * 40,
    "mixed case": "a" * 39 + "F",
    "non-hex letter": "a" * 39 + "g",
    "leading space": " " + "a" * 39,
    "trailing space": "a" * 39 + " ",
    "shell metachar": "a" * 30 + "; rm -rf",
    "build-arg injection": "a" * 23 + " --build-arg X=1",
    "short sha": "abc1234",
    "branch name": "main",
}


def run_prepare(tmp, **env_vars):
    out = Path(tmp) / "gh_output"
    out.write_text("")
    env = {"PATH": os.environ["PATH"], "GITHUB_OUTPUT": str(out)}
    env.update(env_vars)
    p = subprocess.run(["bash", str(PREPARE)], env=env, capture_output=True, text=True)
    return p, out.read_text()


class PrepareTargetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="preparetest.")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def parse(self, text):
        lines = text.splitlines()
        self.assertEqual(
            [l.split("=", 1)[0] for l in lines],
            ["target", "checkout_ref", "plugin_sha"],
            "unexpected output lines: %r" % text,
        )
        return dict(l.split("=", 1) for l in lines)

    def assertRejected(self, label, **env):
        p, out = run_prepare(self.tmp, **env)
        self.assertNotEqual(p.returncode, 0, "%s was accepted: %r" % (label, out))
        self.assertEqual(out, "", "%s wrote to GITHUB_OUTPUT: %r" % (label, out))

    def test_push_paths(self):
        for branch, target in (("main", "prod"), ("staging", "staging")):
            p, out = run_prepare(self.tmp, EVENT="push", PUSH_SHA=SHA_A, REF_NAME=branch)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(
                self.parse(out), {"target": target, "checkout_ref": SHA_A, "plugin_sha": ""}
            )

    def test_push_on_other_branch_is_rejected(self):
        self.assertRejected("push feature", EVENT="push", PUSH_SHA=SHA_A, REF_NAME="feature/x")

    def test_workflow_dispatch_valid(self):
        for ref, target in (("main", "prod"), ("staging", "staging")):
            for sha in ("", SHA_B):
                p, out = run_prepare(
                    self.tmp, EVENT="workflow_dispatch", INPUT_REF=ref, INPUT_SHA=sha
                )
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(
                    self.parse(out), {"target": target, "checkout_ref": ref, "plugin_sha": sha}
                )

    def test_repository_dispatch_valid(self):
        for env, ref, target in (("prod", "main", "prod"), ("staging", "staging", "staging")):
            p, out = run_prepare(
                self.tmp, EVENT="repository_dispatch", PAYLOAD_ENV=env, PAYLOAD_SHA=SHA_C
            )
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(
                self.parse(out), {"target": target, "checkout_ref": ref, "plugin_sha": SHA_C}
            )

    def test_bad_plugin_sha_is_rejected_for_workflow_dispatch(self):
        for label, sha in BAD_SHAS.items():
            self.assertRejected(
                "dispatch input: " + label,
                EVENT="workflow_dispatch", INPUT_REF="staging", INPUT_SHA=sha,
            )

    def test_bad_plugin_sha_is_rejected_for_repository_dispatch(self):
        for label, sha in BAD_SHAS.items():
            self.assertRejected(
                "payload sha: " + label,
                EVENT="repository_dispatch", PAYLOAD_ENV="staging", PAYLOAD_SHA=sha,
            )

    def test_injected_sha_cannot_flip_the_target(self):
        # The reported attack: a staging run whose sha smuggles in "target=prod".
        p, out = run_prepare(
            self.tmp, EVENT="workflow_dispatch", INPUT_REF="staging",
            INPUT_SHA=SHA_A + "\ntarget=prod",
        )
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("target=prod", out)

    def test_ref_must_be_exactly_main_or_staging(self):
        for ref in ("main\ntarget=prod", "staging\n", "MAIN", "main ", " main", "feature",
                    "refs/heads/main", "main;id", "", "production", "prod"):
            self.assertRejected("ref %r" % ref, EVENT="workflow_dispatch", INPUT_REF=ref)

    def test_dispatch_env_must_be_exactly_staging_or_prod(self):
        for env in ("prod\n", "staging\ntarget=prod", "production", "Prod", "main", "", " prod"):
            self.assertRejected(
                "payload env %r" % env, EVENT="repository_dispatch", PAYLOAD_ENV=env
            )

    def test_unknown_event_is_rejected(self):
        self.assertRejected("schedule", EVENT="schedule")

    def test_bad_push_sha_is_rejected(self):
        self.assertRejected(
            "push sha", EVENT="push", REF_NAME="main", PUSH_SHA=SHA_A + "\ntarget=prod"
        )


class DeployScriptValidationTests(unittest.TestCase):
    def test_bad_pin_sha_is_rejected_before_anything_is_built(self):
        for label, sha in BAD_SHAS.items():
            rc, out, err = dry_run(base_env(PIN_SHA=sha))
            self.assertNotEqual(rc, 0, "PIN_SHA %s was accepted" % label)
            self.assertNotIn("DRY_RUN", out, label)

    def test_valid_pin_sha_becomes_exactly_one_build_arg(self):
        script = remote_script(base_env(PIN_SHA=SHA_B))
        m = re.search(r"export BUILD_ARGS=(.*)", script)
        self.assertEqual(
            m.group(1).replace("\\", ""),
            "--build-arg SIWE_BRANCH=main --build-arg SIWE_REF=" + SHA_B,
        )

    def test_bad_deploy_sha_is_rejected(self):
        for label, sha in BAD_SHAS.items():
            rc, _, _ = dry_run(base_env(GITHUB_SHA=sha, DEPLOY_SHA=sha))
            self.assertNotEqual(rc, 0, "DEPLOY_SHA %s was accepted" % label)

    def test_pin_build_arg_must_be_an_identifier(self):
        for name in ("SIWE_REF --privileged", "SIWE_REF\nX", "1X", "A=B", "A-B"):
            rc, _, _ = dry_run(base_env(PIN_BUILD_ARG=name))
            self.assertNotEqual(rc, 0, name)

    def test_unpinned_run_resolves_and_validates_the_branch_tip(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(["git", "init", "-q", "-b", "main", d], check=True)
            env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                       GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
            subprocess.run(["git", "-C", d, "commit", "-q", "--allow-empty", "-m", "x"],
                           check=True, env=env)
            tip = subprocess.run(["git", "-C", d, "rev-parse", "HEAD"], capture_output=True,
                                 text=True, check=True).stdout.strip()
            script = remote_script(base_env(PIN_SHA="", PIN_REPO_URL=d))
            self.assertIn("SIWE_REF=" + tip, script)
            rc, _, err = dry_run(base_env(PIN_SHA="", PIN_REPO_URL=d, PIN_BRANCH="nope"))
            self.assertNotEqual(rc, 0, err)


class DockerfileValidationTests(unittest.TestCase):
    def snippet(self):
        for line in DOCKERFILE.read_text().splitlines():
            if "SIWE_REF" in line and "${#SIWE_REF}" in line:
                return line.strip().rstrip("\\").strip()
        self.fail("no SIWE_REF length check in the Dockerfile")

    def run_check(self, value):
        p = subprocess.run(
            ["sh", "-c", self.snippet() + " echo PASSED"],
            env={"PATH": os.environ["PATH"], "SIWE_REF": value},
            capture_output=True, text=True,
        )
        return p.returncode == 0 and p.stdout.strip() == "PASSED"

    def test_valid_sha_passes(self):
        self.assertTrue(self.run_check(SHA_A))

    def test_bad_values_fail(self):
        for label, sha in BAD_SHAS.items():
            self.assertFalse(self.run_check(sha), "SIWE_REF %s passed" % label)


class WorkflowInputHandlingTests(unittest.TestCase):
    def test_untrusted_expressions_only_appear_as_env_values(self):
        # Interpolating ${{ inputs.* }} or the dispatch payload into a shell script is
        # injectable. They may only be assigned to env vars (KEY: ${{ ... }}).
        for n, line in enumerate(WORKFLOW.read_text().splitlines(), 1):
            if re.search(r"\$\{\{[^}]*(inputs\.|client_payload|head_ref|github\.event\.)", line):
                self.assertRegex(line, r"^\s+[A-Z_]+: \$\{\{ [^}]+ \}\}\s*$", "line %d: %s" % (n, line))

    def test_prepare_step_uses_the_validation_script(self):
        text = WORKFLOW.read_text()
        self.assertIn("bash .github/scripts/prepare-target.sh", text)
        self.assertNotIn("grep -Eq '^[0-9a-f]{40}$'", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
