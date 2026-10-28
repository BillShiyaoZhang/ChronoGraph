"""Local administrator operations. Never pass a password as a command argument."""
import argparse
from datetime import timedelta
from getpass import getpass, GetPassWarning
import warnings
from sqlalchemy import select, update, delete
from pydantic import SecretStr
from .config import Settings
from .database import make_engine, make_sessions
from .models import RegistrationInvite, PasswordCredential, SessionToken, User, now
from .schemas import canonical_username, validate_password
from .security import secret, digest, PasswordSecurity


def parser():
    value = argparse.ArgumentParser(description="ChronoGraph local account administration")
    commands = value.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create-invite", help="Print a new invite secret once; keep stdout private")
    create.add_argument("--days", type=int, default=7, choices=range(1, 366), metavar="1..365")
    create.add_argument("--uses", type=int, default=1, choices=range(1, 101), metavar="1..100")
    revoke = commands.add_parser("revoke-invites", help="Revoke all invites, or one invite by its non-secret UUID")
    revoke.add_argument("--id")
    reset = commands.add_parser("reset-password", help="Prompt privately for a password; revoke every session")
    reset.add_argument("username")
    return value


def main(argv=None):
    args = parser().parse_args(argv)
    sessions = make_sessions(make_engine(Settings.from_env().database_url))
    if args.command == "create-invite":
        raw = secret()
        with sessions() as db:
            invite = RegistrationInvite(digest=digest(raw), expires_at=now() + timedelta(days=args.days),
                                        max_uses=args.uses, uses=0, revoked=False)
            db.add(invite)
            db.commit()
        # Intentionally the only secret emitted by the administrator CLI.
        print(raw)
    elif args.command == "revoke-invites":
        with sessions() as db:
            statement = update(RegistrationInvite).where(RegistrationInvite.revoked.is_(False))
            if args.id:
                statement = statement.where(RegistrationInvite.id == args.id)
            result = db.execute(statement.values(revoked=True))
            db.commit()
            print(f"Revoked {result.rowcount} registration invite(s)")
    else:
        try:
            username = canonical_username(args.username)
            with warnings.catch_warnings():
                # getpass can otherwise fall back to echoed stdin on a non-TTY.
                warnings.simplefilter("error", GetPassWarning)
                first = getpass("New password: ")
                second = getpass("Repeat new password: ")
            if first != second:
                raise ValueError("Passwords do not match")
            validate_password(SecretStr(first))
        except GetPassWarning:
            raise SystemExit("A private interactive terminal is required for password reset") from None
        except (ValueError, EOFError, KeyboardInterrupt) as error:
            raise SystemExit(str(error) or "Password reset cancelled") from None
        encoded = PasswordSecurity().hash(first)
        with sessions() as db:
            credential = db.scalar(select(PasswordCredential).where(PasswordCredential.username == username))
            if credential is None:
                raise SystemExit("Password account is unavailable")
            user = db.scalar(select(User).where(User.id == credential.user_id).with_for_update())
            credential = db.get(PasswordCredential, user.id, populate_existing=True)
            if user.deleted or credential is None:
                raise SystemExit("Password account is unavailable")
            credential.password_hash = encoded
            db.execute(delete(SessionToken).where(SessionToken.user_id == user.id))
            db.commit()
        print("Password reset; all sessions revoked")


if __name__ == "__main__":
    main()
