#!/usr/bin/env python3
"""Regression checks for the Claude task environment security boundary."""

from __future__ import annotations

import json
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEVCONTAINER = REPO_ROOT / ".devcontainer" / "devcontainer.json"
CLAUDE_ENV = REPO_ROOT / "scripts" / "claude-task-env"
DOCKERFILE = REPO_ROOT / "Dockerfile"


class ClaudeTaskEnvSecurityTests(unittest.TestCase):
    """Verify task containers do not receive host Claude credentials/config."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load source files once for the source-level checks."""
        cls.devcontainer_text = DEVCONTAINER.read_text(encoding="utf-8")
        cls.devcontainer = json.loads(cls.devcontainer_text)
        cls.claude_env = CLAUDE_ENV.read_text(encoding="utf-8")
        cls.dockerfile = DOCKERFILE.read_text(encoding="utf-8")

    def test_host_claude_state_is_not_copied_or_mounted(self) -> None:
        """Host Claude credentials/config must never be projected into tasks."""
        forbidden_mount_tokens = (
            "${localEnv:HOME}",
            "/home/dev/.claude",
            ".claude-task",
            ".claude-tasks",
            "TASK_SOURCE_ROOT",
        )
        mount_surfaces = [self.devcontainer["workspaceMount"], *self.devcontainer.get("mounts", [])]

        for surface in mount_surfaces:
            for token in forbidden_mount_tokens:
                with self.subTest(surface=surface, token=token):
                    self.assertNotIn(token, surface)

        up_body = self.claude_env.split("function _cmd_down", maxsplit=1)[0]
        self.assertNotIn(".claude", up_body)
        self.assertNotIn("CLAUDE_CONFIG_DIR", self.dockerfile)

    def test_task_container_does_not_mount_host_source_root(self) -> None:
        """Task containers should only receive the task workspace and named caches."""
        self.assertEqual(
            self.devcontainer["workspaceMount"],
            "source=${localEnv:TASK_WORKTREE},target=/workspace,type=bind",
        )
        self.assertEqual(
            set(self.devcontainer.get("mounts", [])),
            {
                "source=wire-ccache,target=/cache/ccache,type=volume",
                "source=wire-vcpkg,target=/cache/vcpkg,type=volume",
                "source=wire-pnpm,target=/cache/pnpm,type=volume",
                "source=wire-cargo,target=/cache/cargo,type=volume",
            },
        )

    def test_task_container_keeps_default_security_profiles(self) -> None:
        """The task container should not opt out of Docker's default confinement."""
        run_args = self.devcontainer.get("runArgs", [])
        self.assertNotIn("--security-opt", run_args)
        self.assertNotIn("seccomp=unconfined", run_args)
        self.assertNotIn("apparmor=unconfined", run_args)
        self.assertNotIn("label=disable", run_args)

    def test_claude_launch_uses_normal_permissions(self) -> None:
        """Claude should launch without bypassing its permission prompts."""
        self.assertIn("run_exec_in_devcontainer devcontainer-e2e-build", self.claude_env)
        self.assertIn("run_exec_in_devcontainer claude", self.claude_env)
        self.assertNotIn("--permission-mode", self.claude_env)
        self.assertNotIn("bypassPermissions", self.claude_env)

    def test_build_secrets_are_not_persisted_as_image_environment(self) -> None:
        """Optional build tokens must not survive as final-image environment."""
        self.assertNotIn("ENV HUGGING_FACE_HUB_TOKEN", self.dockerfile)


if __name__ == "__main__":
    unittest.main()
