#!/home/anton/.local/share/mempalace/venv/bin/python
"""Create a consistent copy of MemPalace data for the backup exporter."""

from __future__ import annotations

import os
import shutil
import sqlite3
import sys
from pathlib import Path

from mempalace.palace import mine_palace_lock


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} DESTINATION", file=sys.stderr)
        return 2

    source = Path.home() / ".mempalace"
    palace = source / "palace"
    destination = Path(sys.argv[1])

    if not source.is_dir() or not palace.is_dir():
        print(f"MemPalace data directory not found: {source}", file=sys.stderr)
        return 1
    if destination.exists():
        print(f"Destination already exists: {destination}", file=sys.stderr)
        return 1

    # MemPalace writers use this lock. If a mine/MCP write is active, fail the
    # backup instead of capturing mismatched SQLite and vector-index files.
    with mine_palace_lock(str(palace)):
        shutil.copytree(
            source,
            destination,
            symlinks=True,
            ignore=shutil.ignore_patterns("locks", "*.lock", "*-wal", "*-shm"),
        )

        source_db = palace / "chroma.sqlite3"
        if source_db.is_file():
            destination_db = destination / "palace" / "chroma.sqlite3"
            temporary_db = destination_db.with_suffix(".sqlite3.backup-tmp")
            if temporary_db.exists():
                temporary_db.unlink()

            source_uri = f"file:{source_db}?mode=ro"
            with sqlite3.connect(source_uri, uri=True) as source_connection:
                with sqlite3.connect(temporary_db) as destination_connection:
                    source_connection.backup(destination_connection)
                    result = destination_connection.execute(
                        "PRAGMA integrity_check"
                    ).fetchone()

            if not result or result[0] != "ok":
                temporary_db.unlink(missing_ok=True)
                print("MemPalace SQLite integrity check failed", file=sys.stderr)
                return 1

            os.replace(temporary_db, destination_db)

    print(f"MemPalace snapshot created: {destination}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
