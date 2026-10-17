from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tools" / "vessel-cli"
OUTPUT = ROOT / "apps" / "marketing" / "public" / "assets" / "downloads"


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="vessel-cli-wheel-") as temporary:
        clean_source = Path(temporary) / "vessel-cli"
        clean_source.mkdir()
        shutil.copy2(SOURCE / "pyproject.toml", clean_source / "pyproject.toml")
        shutil.copytree(
            SOURCE / "vessel_cli",
            clean_source / "vessel_cli",
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
        subprocess.run(
            [
                "uv",
                "build",
                "--wheel",
                "--out-dir",
                str(OUTPUT),
                "--clear",
                "--no-create-gitignore",
                str(clean_source),
            ],
            check=True,
        )


if __name__ == "__main__":
    main()
