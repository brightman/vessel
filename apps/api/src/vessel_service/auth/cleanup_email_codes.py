"""Delete one bounded batch of expired registration state; never print addresses/codes."""
import argparse
from datetime import UTC, datetime, timedelta
from sqlalchemy import delete, select
from sqlalchemy.orm import Session
from vessel_service.auth.email_verification import lock_registration
from vessel_service.database import create_database_engine
from vessel_service.models.registration_email import RegistrationEmailChallenge, RegistrationEmailLimit
from vessel_service.settings import Settings


def cleanup(session: Session, *, retention_days: int = 7, batch_size: int = 1000) -> dict[str, int]:
    if not 1 <= retention_days <= 365 or not 1 <= batch_size <= 10000:
        raise ValueError("Cleanup limits out of range")
    lock_registration(session)
    cutoff = datetime.now(UTC) - timedelta(days=retention_days)
    counts = {}
    for model, key, name in [(RegistrationEmailChallenge, RegistrationEmailChallenge.challenge_id, "challenges"), (RegistrationEmailLimit, RegistrationEmailLimit.bucket_key, "limits")]:
        expired = select(key).where(model.expires_at < cutoff).order_by(model.expires_at, key).limit(batch_size)
        result = session.execute(delete(model).where(key.in_(expired)).execution_options(synchronize_session=False))
        counts[name] = result.rowcount
    session.commit()
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--retention-days", type=int, default=7)
    parser.add_argument("--batch-size", type=int, default=1000)
    args = parser.parse_args()
    settings = Settings()
    if not settings.database_url:
        parser.error("NOTES_DATABASE_URL is required")
    with Session(create_database_engine(settings.database_url)) as session:
        print(cleanup(session, retention_days=args.retention_days, batch_size=args.batch_size))

if __name__ == "__main__":
    main()
