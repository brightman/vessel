from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError


_hasher = PasswordHasher()
_dummy_password_hash = _hasher.hash("pages-invalid-login-dummy-password")


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str | None, password: str) -> bool:
    try:
        matches = _hasher.verify(password_hash or _dummy_password_hash, password)
        return bool(password_hash) and matches
    except (InvalidHashError, VerifyMismatchError):
        return False
