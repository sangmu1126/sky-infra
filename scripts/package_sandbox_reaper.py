"""Package only the trusted checked-in handler; no dependency installation."""

from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


def main():
    root = Path(__file__).resolve().parents[1]
    destination = root / "terraform/envs/security-sandbox/.terraform/sandbox-reaper.zip"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(destination, "w", compression=ZIP_DEFLATED) as archive:
        info = ZipInfo("sandbox_reaper.py", date_time=(2026, 1, 1, 0, 0, 0))
        info.external_attr = 0o644 << 16
        archive.writestr(info, (root / "scripts/sandbox_reaper.py").read_bytes())
    print("Packaged trusted sandbox deadline handler")


if __name__ == "__main__":
    main()
