"""OFF identity against pinned main sources and versioned render fixtures.

Same Compose version: compare untouched stdout bytes. Different versions:
parse YAML (mapping order, quoting and indentation are immaterial) and drop
bind.create_host_path on bind mounts: Compose versions disagree on it (v5.4.0
on macOS writes true, the older Compose on GitHub's ubuntu runners omits it).
OFF identity itself rests on the pinned SHA-256 of the base files and the exact
file selection, both version-independent. No paths, environment values, other
service fields or list ordering are removed. Unexpected differences FAIL.
"""

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from types import SimpleNamespace
from unittest import mock

import yaml


GIT_ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("K1_OFF_RENDER_ROOT", GIT_ROOT))
# Raw stdout captured from `git archive 93afd045bf9ab59817fa6125c0bd4172cb4bab89`
# extracted in a disposable directory, using Docker Compose v5.4.0 and the same
# command/environment below. --no-path-resolution preserves portable bind paths.
# Amended five times: the 2026-10-27 postgres:16-alpine digest re-pin (one image
# line), T-1433 (QI engine off by default: the QI_ENGINE_ENABLED value
# line in each render), kit 2.0 K-A (the new sanitizer core services +
# their gateway/witness/sandbox-b wiring — additions only, see
# baseline.json "amended_kit_2_0") and its DSN follow-up (the core's
# --dsn line became --registry-dsn-file + one bind of the DSN file, see
# "amended_kit_2_0_dsn") and its fix round 1 (the pair's REQUIRED signed
# digests + the core's dedicated internal networks, see
# "amended_kit_2_0_fix1") and its final-read round (core/sidecar hardening
# lines, see "amended_kit_2_0_final_reads") and kit 2.0 K-E's third-party
# digest pins (the image lines only, see "amended_kit_2_0_row9_pins") and the
# kit 2.0.0 version bump (the dsa-* image tag lines only, see
# "amended_kit_2_0_0_bump"), each with the compose file hashes in
# baseline.json; nothing else in the fixtures changed.
GOLDEN = GIT_ROOT / "tests/fixtures/servicenow-control/off"
BASELINE = json.loads((GOLDEN / "baseline.json").read_text())
FILES = ("docker-compose.customer.yml", "docker-compose.self-hosted.yml",
         "docker-compose.self-hosted-byok.yml")
PATHS = ("customer", "self-hosted", "self-hosted-byok")


def command(*args):
    # Exclude ambient interpolation values (including real credentials).
    env = {key: os.environ[key] for key in ("PATH", "HOME") if key in os.environ}
    return subprocess.run(args, cwd=ROOT, env=env, capture_output=True, timeout=30)


def normalise(document):
    document = copy.deepcopy(document)
    for service in document["services"].values():
        for mount in service.get("volumes", []):
            if mount.get("type") == "bind":
                bind = mount.get("bind")
                if isinstance(bind, dict):
                    bind.pop("create_host_path", None)
                    if not bind:
                        mount.pop("bind")
    return document


def assert_render_equal(test, expected, actual, version):
    if version == BASELINE["compose_version"]:
        test.assertEqual(expected, actual)
    else:
        test.assertEqual(normalise(yaml.safe_load(expected)), normalise(yaml.safe_load(actual)))


class OffRenderTests(unittest.TestCase):
    def test_off_base_files_byte_identical_to_pinned_main(self):
        self.assertEqual(set(FILES), set(BASELINE["sha256"]))
        for file in FILES:
            with self.subTest(file=file):
                self.assertEqual(BASELINE["sha256"][file],
                                 hashlib.sha256((ROOT / file).read_bytes()).hexdigest())

    def test_off_passes_exact_base_file_sequence_without_overlay(self):
        spec = importlib.util.spec_from_file_location("off_renderer", GIT_ROOT / "scripts/render-servicenow-control.py")
        renderer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(renderer)
        for count, path in enumerate(PATHS, 1):
            with self.subTest(path=path), mock.patch.object(renderer.subprocess, "run") as run:
                run.return_value = subprocess.CompletedProcess([], 0, b"ordinary", b"")
                args = SimpleNamespace(mode="off", path=path, project_name="k1-off",
                                       env_file=GOLDEN / "synthetic.env.fixture")
                self.assertEqual(b"ordinary", renderer.render(args))
                run.assert_called_once()
                self.assertEqual(["docker", "compose", "--env-file", str(args.env_file.resolve()),
                    "--project-directory", str(renderer.ROOT), "--project-name", "k1-off",
                    *[arg for file in FILES[:count] for arg in ("-f", str(renderer.ROOT / file))],
                    "config"], run.call_args.args[0])

    def test_off_render_bytes_equal_main(self):
        version = command("docker", "compose", "version")
        self.assertEqual(0, version.returncode, version.stderr.decode())
        version = version.stdout.decode().strip()
        self.assertTrue(version)
        comparison = "bytes" if version == BASELINE["compose_version"] else "normalised YAML"
        print("OFF identity: " + comparison + " (" + version + ")")
        for count, path in enumerate(PATHS, 1):
            with self.subTest(path=path):
                files = [arg for file in FILES[:count] for arg in ("-f", str(ROOT / file))]
                after = command("docker", "compose", "--env-file", str(GOLDEN / "synthetic.env.fixture"),
                                "--project-directory", str(ROOT), "--project-name", "k1-off",
                                *files, "config", "--no-path-resolution")
                self.assertEqual(0, after.returncode, after.stderr.decode())
                assert_render_equal(self, (GOLDEN / (path + ".yaml")).read_bytes(), after.stdout, version)

    def test_versioned_comparison_exercises_both_branches_and_rejects_changes(self):
        expected = b'services:\n  gateway:\n    image: "original"\n    volumes:\n      - type: bind\n        source: ./certs\n        target: /certs\n        bind: {create_host_path: false}\n'
        different_format = yaml.safe_dump(yaml.safe_load(expected)).encode()
        with self.assertRaises(AssertionError):
            assert_render_equal(self, expected, different_format, BASELINE["compose_version"])
        legacy = yaml.safe_load(different_format)
        del legacy["services"]["gateway"]["volumes"][0]["bind"]
        legacy_bytes = yaml.safe_dump(legacy).encode()
        assert_render_equal(self, expected, legacy_bytes, "different-version")
        for alteration in (b'original', b'./certs'):
            with self.subTest(alteration=alteration), self.assertRaises(AssertionError):
                assert_render_equal(self, expected, legacy_bytes.replace(alteration, b'changed'), "different-version")
        # create_host_path differs between Compose versions and is ignored across versions.
        legacy["services"]["gateway"]["volumes"][0]["bind"] = {"create_host_path": True}
        assert_render_equal(self, expected, yaml.safe_dump(legacy).encode(), "different-version")
        legacy["services"]["gateway"]["volumes"][0]["read_only"] = True
        with self.assertRaises(AssertionError):
            assert_render_equal(self, expected, yaml.safe_dump(legacy).encode(), "different-version")

    def test_overlay_only_selected_by_the_opt_in(self):
        # Kit 2.0 K-C: the overlay is now selected by bin/lucairn, but ONLY
        # through the opt-in resolver; the base files, lucairn-init and the
        # release scripts never name it, and nothing names the review renderer.
        tokens = ("bootstrap-servicenow-control", "render-servicenow-control", "docker-compose.servicenow-control")
        for file in ("scripts/bootstrap-servicenow-control.py", "scripts/render-servicenow-control.py",
                     "docker-compose.servicenow-control.yml", "bin/lucairn-servicenow.py"):
            self.assertTrue((ROOT / file).is_file())
        for name in [*FILES, "bin/lucairn-init", "scripts/package-release.sh", "scripts/release-kit.sh"]:
            path = ROOT / name
            if path.is_file():
                for token in tokens:
                    self.assertNotIn(token.encode(), path.read_bytes(), name)
        cli = (ROOT / "bin/lucairn").read_text()
        self.assertNotIn("render-servicenow-control", cli)
        self.assertEqual(1, cli.count("docker-compose.servicenow-control"), "one constant names the overlay")
        self.assertIn('SERVICENOW_OVERLAY="docker-compose.servicenow-control.yml"', cli)
        # The overlay enters the Compose arguments in exactly one place, behind SN_STATE=on.
        self.assertEqual(1, cli.count('RUNTIME_COMPOSE_ARGS+=(-f "$overlay")\n  fi\n  if [ "$mode" = "local-runtime" ]'))
        selection = cli.index('RUNTIME_COMPOSE_ARGS+=(-f "$overlay")\n  fi\n  if [ "$mode" = "local-runtime" ]')
        self.assertIn('if [ "$SN_STATE" = "on" ]; then', cli[selection - 400:selection])


if __name__ == "__main__":
    unittest.main()
