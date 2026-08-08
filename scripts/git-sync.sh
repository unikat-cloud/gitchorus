#!/usr/bin/env bash
#
# gitchorus — Bidirektionaler, SHA-identischer Git-Sync zwischen GitHub und
# GitLab (nur main + Tags).
#
# Beide Seiten sind exakt identisch: gleiche Commits, gleiche SHAs, gleiche
# Tags. Plattformspezifische CI-Dateien (.gitlab-ci.yml, .github/) liegen auf
# BEIDEN Seiten — jede Plattform führt nur ihre eigene aus (GitHub ignoriert
# .gitlab-ci.yml, GitLab ignoriert .github/). Dadurch ist kein Rewrite nötig
# und die Loop-Erkennung funktioniert wieder per SHA-Vergleich.
#
# Umgebungsvariablen (von der jeweiligen CI gesetzt):
#   TARGET_REMOTE_URL  z.B. https://gitlab.../group/repo.git oder file://
#   TARGET_TOKEN       PAT der Gegenseite (write_repository / Contents:RW)
#   TARGET_USER        User-Prefix in der URL (GitLab: oauth2, GitHub: x-access-token)
#   BRANCH             zu spiegelnder Branch (hier: main)
#   FROM_SHA           Vorgänger-SHA des Pushes (CI stellt es bereit; "0000..." bei neuem Branch)
#   TO_SHA             aktueller SHA des Pushes
#
# Rückgabe 0 = nichts zu tun (Echo erkannt) ODER erfolgreich gepusht; 1 = Fehler.
set -euo pipefail

# ---- Konfiguration / Sicherheit -------------------------------------------------
: "${TARGET_REMOTE_URL:?TARGET_REMOTE_URL fehlt}"
: "${TARGET_TOKEN:?TARGET_TOKEN fehlt}"
: "${TARGET_USER:=oauth2}"
: "${BRANCH:=main}"
: "${FROM_SHA:=0000000000000000000000000000000000000000}"
: "${TO_SHA:?"TO_SHA fehlt"}"

# Token niemals in Logs leaken + keine interaktiven Passwort-Prompts
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

# Git-Safe-Directory für CI-Umgebungen (Permissions anders als beim Rider)
git config --global --add safe.directory '*' >/dev/null 2>&1 || true

# Token-URL so aufbauen, dass der Token NICHT in Logs/Ausgaben erscheint.
# Bei lokalen Pfaden / file://-URLs (z.B. Sandbox-Test) wird keine Auth benötigt.
if [[ "$TARGET_REMOTE_URL" == file://* ]] || [[ "$TARGET_REMOTE_URL" != *://* ]]; then
  REMOTE_URL="$TARGET_REMOTE_URL"
else
  scheme="${TARGET_REMOTE_URL%%://*}"
  rest="${TARGET_REMOTE_URL#*://}"
  REMOTE_URL="${scheme}://${TARGET_USER}:${TARGET_TOKEN}@${rest}"
fi
export REMOTE_URL

log()  { printf '[git-sync] %s\n' "$*"; }
err()  { printf '[git-sync][ERROR] %s\n' "$*" >&2; }

TARGET_REF="refs/remotes/target/heads/${BRANCH}"

# ---- Ziel-Remote vorbereiten ----------------------------------------------------
# Falls Remote bereits existiert (Mehrfachlauf im selben Runner), nur URL aktualisieren.
if ! git remote get-url target >/dev/null 2>&1; then
  git remote add target "$REMOTE_URL"
else
  git remote set-url target "$REMOTE_URL"
fi

# Branches + Tags des Ziels holen (für Echo-Erkennung und Tag-Vergleich).
git fetch --no-tags --prune target \
  "+refs/heads/*:refs/remotes/target/heads/*" "+refs/tags/*:refs/remotes/target/tags/*" \
  >/dev/null 2>&1 || true   # Abbruchrechte auf der Gegenseite sind in Ordnung (Netzwerk/Permissions)

# ---- Echo-/Schleifen-Erkennung ---------------------------------------------------
# Ein von der Gegenseite gespiegelter Push enthält exakt DIESELBEN Commit-SHAs,
# die bereits auf dem Ziel existieren. Existieren ALLE neuen Commits dieses
# Pushes bereits auf dem Ziel-Remote, handelt es sich um unseren eigenen Echo-Push.
new_commits="$( { git rev-list "${FROM_SHA}..${TO_SHA}" 2>/dev/null || true; } )"
if [ -z "$new_commits" ]; then
  # Kein Commit-Bereich (z.B. neuer Branch): Head prüfen.
  new_commits="$TO_SHA"
fi

all_on_target=1
for sha in $new_commits; do
  if ! git merge-base --is-ancestor "$sha" "$TARGET_REF" >/dev/null 2>&1; then
    all_on_target=0
    break
  fi
done

# Tags, die das Ziel noch nicht hat (auch bei "Echo"-Branches spiegeln!).
missing_tags=""
for tag in $(git tag); do
  if ! git rev-parse -q --verify "refs/remotes/target/tags/${tag}" >/dev/null 2>&1; then
    missing_tags="$missing_tags $tag"
  fi
done

if [ "$all_on_target" = "1" ] && [ -z "$missing_tags" ]; then
  log "Echo-Push erkannt (alle Commits bereits auf '$BRANCH' des Ziel-Remotes, keine fehlenden Tags). Skip, keine Schleife."
  exit 0
fi

if [ "$all_on_target" = "1" ]; then
  log "Branch-Commit bereits auf dem Ziel-Remote (Echo), aber ${missing_tags} Tags fehlen dort noch."
fi

# ---- Branch pushen ---------------------------------------------------------------
if [ "$all_on_target" = "0" ]; then
  # CIs checken `main` detached aus (kein lokaler Branch-Ref) – deshalb SHA-basiert pushen.
  log "Push '${BRANCH}' (${FROM_SHA:0:8} → ${TO_SHA:0:8}) nach Ziel-Remote."
  if ! git push target "${TO_SHA}:refs/heads/${BRANCH}"; then
    err "Push abgelehnt (Konflikt / rejected). Siehe Pipeline-Logs."
    exit 1
  fi
fi

# ---- Tags spiegeln ---------------------------------------------------------------
# Nur Tags pushen, die das Ziel noch nicht hat (kein --force, kein Tag-Rewrite).
for tag in $missing_tags; do
  if git push target "refs/tags/${tag}:refs/tags/${tag}"; then
    log "Tag '${tag}' nach Ziel-Remote gespiegelt."
  else
    err "Tag '${tag}' konnte nicht gepusht werden (Konflikt / rejected)."
  fi
done

log "Synchronisation abgeschlossen."
