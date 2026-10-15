"""Compare ordinary Compose output to the assigned main baseline, without startup."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SCRATCH = "/private/tmp" if Path("/private/tmp").is_dir() else str(Path(tempfile.gettempdir()).resolve())

GIT_ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("K1_OFF_RENDER_ROOT", GIT_ROOT))
# The assigned baseline is this worktree's HEAD; do not pin a moving main SHA.
BASE = "HEAD"
FILES = ("docker-compose.customer.yml", "docker-compose.self-hosted.yml",
         "docker-compose.self-hosted-byok.yml")


def command(*args):
    return subprocess.run(args, cwd=GIT_ROOT, capture_output=True, timeout=30)


class OffRenderTests(unittest.TestCase):
    def test_off_render_bytes_equal_main(self):
        with tempfile.TemporaryDirectory(prefix="k1-off-", dir=SCRATCH) as name:
            scratch = Path(name)
            baseline = []
            for file in FILES:
                result = command("git", "show", f"{BASE}:{file}")
                self.assertEqual(0, result.returncode)
                path = scratch / file
                path.write_bytes(result.stdout)
                baseline.append(path)
            # Values only satisfy existing required interpolation; no real service calls.
            required = set(re.findall(rb"\$\{([A-Z0-9_]+):\?", b"".join(p.read_bytes() for p in baseline)))
            env = scratch / "synthetic.env"
            env.write_text("".join(key.decode() + "=k1-synthetic\n" for key in sorted(required)))
            base_command = ("docker", "compose", "--env-file", str(env),
                            "--project-directory", str(ROOT), "--project-name", "k1-off")
            for count in (1, 2, 3):
                with self.subTest(compose_files=count):
                    before_args = [arg for p in baseline[:count] for arg in ("-f", str(p))]
                    after_args = [arg for p in FILES[:count] for arg in ("-f", str(ROOT / p))]
                    before = command(*base_command, *before_args, "config")
                    after = command(*base_command, *after_args, "config")
                    self.assertEqual(0, before.returncode, before.stderr.decode())
                    self.assertEqual(0, after.returncode, after.stderr.decode())
                    self.assertEqual(before.stdout, after.stdout)

    def test_bootstrap_has_no_existing_startup_reference(self):
        # Positive existence prevents a vacuous "not referenced" result after deletion.
        tokens = ("bootstrap-servicenow-control", "render-servicenow-control", "docker-compose.servicenow-control")
        for file in ("scripts/bootstrap-servicenow-control.py", "scripts/render-servicenow-control.py",
                     "docker-compose.servicenow-control.yml"):
            self.assertTrue((ROOT / file).is_file())
        # Check startup/packaging entry points, rather than scanning the whole repo.
        names = [*FILES, "bin/lucairn", "bin/lucairn-init", "scripts/package-release.sh", "scripts/release-kit.sh"]
        for name in names:
            path = ROOT / name
            if path.is_file():
                for token in tokens:
                    self.assertNotIn(token.encode(), path.read_bytes(), name)


if __name__ == "__main__":
    unittest.main()
