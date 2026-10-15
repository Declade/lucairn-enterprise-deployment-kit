"""Compare ordinary Compose output to captured main bytes, without startup."""

import os
from pathlib import Path
import subprocess
import unittest


GIT_ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("K1_OFF_RENDER_ROOT", GIT_ROOT))
# Raw stdout captured from `git archive 93afd045bf9ab59817fa6125c0bd4172cb4bab89`
# extracted in a disposable directory, using Docker Compose v5.4.0 and the same
# command/environment below. --no-path-resolution preserves portable bind paths;
# neither the captured bytes nor the current stdout are rewritten for comparison.
GOLDEN = GIT_ROOT / "tests/fixtures/servicenow-control/off"
FILES = ("docker-compose.customer.yml", "docker-compose.self-hosted.yml",
         "docker-compose.self-hosted-byok.yml")
PATHS = ("customer", "self-hosted", "self-hosted-byok")


def command(*args):
    # Exclude ambient interpolation values (including real credentials).
    env = {key: os.environ[key] for key in ("PATH", "HOME") if key in os.environ}
    return subprocess.run(args, cwd=ROOT, env=env, capture_output=True, timeout=30)


class OffRenderTests(unittest.TestCase):
    def test_off_render_bytes_equal_main(self):
        for count, path in enumerate(PATHS, 1):
            with self.subTest(path=path):
                files = [arg for file in FILES[:count] for arg in ("-f", str(ROOT / file))]
                after = command("docker", "compose", "--env-file", str(GOLDEN / "synthetic.env"),
                                "--project-directory", str(ROOT), "--project-name", "k1-off",
                                *files, "config", "--no-path-resolution")
                self.assertEqual(0, after.returncode, after.stderr.decode())
                self.assertEqual((GOLDEN / (path + ".yaml")).read_bytes(), after.stdout)

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
