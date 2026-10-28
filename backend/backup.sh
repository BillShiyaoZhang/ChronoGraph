#!/bin/sh
set -eu
umask 077
CHRONOGRAPH_ROOT=${CHRONOGRAPH_ROOT:-/opt/chronograph}
CHRONOGRAPH_BACKUPS=${CHRONOGRAPH_BACKUPS:-$CHRONOGRAPH_ROOT/backups}
mkdir -p "$CHRONOGRAPH_BACKUPS"
CHRONOGRAPH_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
CHRONOGRAPH_TARGET="$CHRONOGRAPH_BACKUPS/chronograph-$CHRONOGRAPH_STAMP.dump"
test ! -e "$CHRONOGRAPH_TARGET"
trap 'rm -f "$CHRONOGRAPH_TARGET.partial"' EXIT HUP INT TERM
docker compose --project-name chronograph \
  --env-file "$CHRONOGRAPH_ROOT/secrets.env" \
  -f "$CHRONOGRAPH_ROOT/current/backend/compose.yml" \
  exec -T db pg_dump -U chronograph -d chronograph --no-owner -Fc \
  > "$CHRONOGRAPH_TARGET.partial"
test -s "$CHRONOGRAPH_TARGET.partial"
mv "$CHRONOGRAPH_TARGET.partial" "$CHRONOGRAPH_TARGET"
printf '%s\n' "$CHRONOGRAPH_TARGET"
# Retain the newest 14 daily dump files; never prune a partial or foreign file.
python3 - "$CHRONOGRAPH_BACKUPS" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
backups = sorted((p for p in root.iterdir() if re.fullmatch(r'chronograph-\d{8}T\d{6}Z\.dump', p.name) and p.is_file()), reverse=True)
for path in backups[14:]:
    path.unlink()
PY
