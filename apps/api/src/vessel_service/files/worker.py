"""Run durable file work independently of HTTP response background scheduling."""

import argparse
import time

from sqlalchemy.orm import sessionmaker

from vessel_service.database import create_database_engine
from vessel_service.settings import Settings

from .jobs import expire_uploads, process_jobs
from .storage import FilesSettings, OSSStorage


def main():
    parser = argparse.ArgumentParser(description="Vessel file outbox worker")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--interval", type=float, default=2.0)
    args = parser.parse_args()
    if args.interval <= 0:
        parser.error("interval must be positive")
    settings = Settings()
    if not settings.database_url:
        parser.error("PAGES_DATABASE_URL required")
    engine = create_database_engine(settings.database_url)
    sessions = sessionmaker(bind=engine, expire_on_commit=False)
    storage = OSSStorage(FilesSettings())
    try:
        while True:
            expire_uploads(sessions)
            count = process_jobs(sessions, storage)
            if args.once:
                print(f"File jobs processed: {count}")
                break
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
