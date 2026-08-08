#!/usr/bin/env bash
#
# sandbox-sync.sh — Lokale Verifikation des SHA-identischen Syncs + Loop-Schutzes.
#
# Simuliert zwei "Remote-Seiten" (GitHub-Ersatz / GitLab-Ersatz) über lokale
# Bare-Repositories. Erwartung:
#   - echter Sync läuft durch (PUSH), SHA-identisch
#   - Echo-Sync    skippt      (SKIP, keine Schleife)
#   - Tags werden mitgespiegelt (auch wenn die Commits schon auf dem Ziel sind)
#   - beide Seiten haben identische Trees (inkl. .github/ und .gitlab-ci.yml)
#
# Aufruf: bash test/sandbox-sync.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SH="$SCRIPT_DIR/scripts/git-sync.sh"
SANDBOX="$(mktemp -d)"
GH_REPO="$SANDBOX/gh.git"
GL_REPO="$SANDBOX/gl.git"
GH_DEV="$SANDBOX/gh-dev"
GL_DEV="$SANDBOX/gl-dev"
ZERO=0000000000000000000000000000000000000000
PASS=0; FAIL=0
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

check() { # $1 Name, $2 erwartet (PUSH|SKIP), $3 Ausgabe
  if echo "$3" | grep -q "Echo-Push erkannt"; then got=SKIP; else got=PUSH; fi
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); echo "  ✔ $1 → $got (korrekt)"
  else FAIL=$((FAIL+1)); echo "  ✘ $1 → $got, erwartet $2"; echo "$3"; fi
}

# Prüft, dass ein Pfad in einer Bare-Repo-Ref existiert.
expect_in_repo() { # $1 Name, $2 Bare-Repo, $3 Ref, dann "+pfad" ...
  local name="$1" repo="$2" ref="$3" arg path ok=1
  shift 3
  for arg in "$@"; do
    path="${arg:1}"
    if git -C "$repo" cat-file -e "$ref:$path" 2>/dev/null; then has=1; else has=0; fi
    if [ "${arg:0:1}" = "+" ] && [ "$has" = 0 ]; then
      echo "  ✘ $name: '$path' fehlt auf $repo"; FAIL=$((FAIL+1)); ok=0
    elif [ "${arg:0:1}" = "-" ] && [ "$has" = 1 ]; then
      echo "  ✘ $name: '$path' existiert unerwartet auf $repo"; FAIL=$((FAIL+1)); ok=0
    fi
  done
  [ "$ok" = 1 ] && PASS=$((PASS+1))
}

# Prüft, dass beide Repos identische main-SHAs + gleiche Bäume haben.
expect_identical() { # $1 Name
  local gh_sha gl_sha
  gh_sha="$(git -C "$GH_REPO" rev-parse main 2>/dev/null)"
  gl_sha="$(git -C "$GL_REPO" rev-parse main 2>/dev/null)"
  if [ -n "$gh_sha" ] && [ "$gh_sha" = "$gl_sha" ]; then
    PASS=$((PASS+1)); echo "  ✔ $1 → identisch ($gh_sha)"
  else
    FAIL=$((FAIL+1)); echo "  ✘ $1 → GitHub=$gh_sha GitLab=$gl_sha"
  fi
}

# Sync aus einem Dev-Clone heraus ausführen (simuliert die jeweilige CI).
run_sync() { # $1 Dev-Clone, $2 Ziel-Repo, $3 Ziel-User, $4 FROM_SHA, $5 TO_SHA
  local dev="$1" target="$2" user="$3" from="$4" to="$5"
  ( cd "$dev" && TARGET_REMOTE_URL="file://$target" TARGET_TOKEN=x TARGET_USER="$user" \
    BRANCH=main FROM_SHA="$from" TO_SHA="$to" \
    bash "$SYNC_SH" 2>&1 || true )
}

# --- Setup ---------------------------------------------------------------------
git init --bare -q "$GH_REPO"
git init --bare -q "$GL_REPO"
git --git-dir="$GH_REPO" symbolic-ref HEAD refs/heads/main
git --git-dir="$GL_REPO" symbolic-ref HEAD refs/heads/main

git clone -q "$GH_REPO" "$GH_DEV"
cd "$GH_DEV"
git config user.email dev@example.com; git config user.name Dev
git branch -M main
mkdir -p .github/workflows
echo "workflow" > .github/workflows/ci.yml
echo "ci config" > .gitlab-ci.yml
echo "hi from github" > notes.txt
git add .; git commit -qm "A: erste Datei (CI-Dateien auf beiden Seiten)"
SHA_A="$(git rev-parse HEAD)"
git push -q origin main

# --- Szenario 1: Dev pusht A auf GitHub; GitHub-Actions spiegelt → GitLab --------
echo "== Szenario 1: GitHub-Actions spiegelt A nach GitLab (erwartet PUSH) =="
out=$(run_sync "$GH_DEV" "$GL_REPO" oauth2 "$ZERO" "$SHA_A")
check "Sync GitHub→GitLab (A)" PUSH "$out"
expect_identical "Identität nach A"

echo "== Szenario 1b: CI-Dateien sind auf beiden Seiten =="
expect_in_repo "Identische Dateien nach A" "$GL_REPO" main "+.github/workflows/ci.yml" "+.gitlab-ci.yml" "+notes.txt"

# --- Szenario 2: Echo-Trigger auf GitLab (gleiche Commits liegen schon dort) ----
echo "== Szenario 2: GitLab-Echo spiegelt zurück (erwartet SKIP) =="
rm -rf "$GL_DEV"; git clone -q "$GL_REPO" "$GL_DEV"
GL_HEAD="$(git -C "$GL_DEV" rev-parse HEAD)"
out=$(run_sync "$GL_DEV" "$GH_REPO" x-access-token "$ZERO" "$GL_HEAD")
check "Echo GitLab→GitHub (A)" SKIP "$out"

# --- Szenario 3: Dev pusht B auf GitHub; spiegelt → GitLab ----------------------
echo "== Szenario 3: GitHub-Actions spiegelt B nach GitLab (erwartet PUSH) =="
cd "$GH_DEV"; echo "more" >> notes.txt; git add .; git commit -qm "B: zweite Änderung"
git push -q origin main
SHA_B="$(git rev-parse HEAD)"; cd ..
out=$(run_sync "$GH_DEV" "$GL_REPO" oauth2 "$SHA_A" "$SHA_B")
check "Sync GitHub→GitLab (B)" PUSH "$out"
expect_identical "Identität nach B"

# --- Szenario 4: Echo-Trigger auf GitLab für B ----------------------------------
echo "== Szenario 4: GitLab-Echo spiegelt B zurück (erwartet SKIP) =="
rm -rf "$GL_DEV"; git clone -q "$GL_REPO" "$GL_DEV"
GL_HEAD="$(git -C "$GL_DEV" rev-parse HEAD)"
out=$(run_sync "$GL_DEV" "$GH_REPO" x-access-token "$ZERO" "$GL_HEAD")
check "Echo GitLab→GitHub (B)" SKIP "$out"

# --- Szenario 5: GitLab-seitige Änderung → spiegelt nach GitHub -----------------
echo "== Szenario 5: GitLab-Änderung C spiegelt nach GitHub (erwartet PUSH) =="
rm -rf "$GL_DEV"; git clone -q "$GL_REPO" "$GL_DEV"
cd "$GL_DEV"
git config user.email dev@example.com; git config user.name Dev
echo "hi from gitlab" > notes-gl.txt
git add .; git commit -qm "C: GitLab-Änderung"
SHA_C="$(git rev-parse HEAD)"
git push -q origin main
out=$(run_sync "$GL_DEV" "$GH_REPO" x-access-token "$ZERO" "$SHA_C")
check "Sync GitLab→GitHub (C)" PUSH "$out"
expect_identical "Identität nach C"

# --- Szenario 6: Echo-Trigger auf GitHub für C ----------------------------------
echo "== Szenario 6: GitHub-Echo spiegelt C zurück (erwartet SKIP) =="
rm -rf "$GH_DEV"; git clone -q "$GH_REPO" "$GH_DEV"
GH_HEAD="$(git -C "$GH_DEV" rev-parse HEAD)"
out=$(run_sync "$GH_DEV" "$GL_REPO" oauth2 "$ZERO" "$GH_HEAD")
check "Echo GitHub→GitLab (C)" SKIP "$out"

# --- Szenario 7: Tag auf GitHub → wird gespiegelt (Commits schon auf GitLab) ----
echo "== Szenario 7: GitHub-Tag v1.0.0 spiegelt nach GitLab (erwartet PUSH) =="
cd "$GH_DEV"; git tag v1.0.0; git push -q origin v1.0.0
out=$(run_sync "$GH_DEV" "$GL_REPO" oauth2 "$ZERO" "$GH_HEAD")
check "Tag-Sync GitHub→GitLab (v1.0.0)" PUSH "$out"
expect_in_repo "Tag auf GitLab" "$GL_REPO" main "+.github/workflows/ci.yml"
if git -C "$GL_REPO" rev-parse -q --verify refs/tags/v1.0.0 >/dev/null 2>&1; then
  PASS=$((PASS+1)); echo "  ✔ Tag v1.0.0 auf GitLab vorhanden"
else
  FAIL=$((FAIL+1)); echo "  ✘ Tag v1.0.0 fehlt auf GitLab"
fi

# --- Szenario 8: Echo-Tag-Push von GitLab → keine Schleife ----------------------
echo "== Szenario 8: GitLab-Echo für Tag (erwartet SKIP) =="
rm -rf "$GL_DEV"; git clone -q "$GL_REPO" "$GL_DEV"
GL_HEAD="$(git -C "$GL_DEV" rev-parse HEAD)"
out=$(run_sync "$GL_DEV" "$GH_REPO" x-access-token "$ZERO" "$GL_HEAD")
check "Echo Tag GitLab→GitHub" SKIP "$out"

echo
echo "Ergebnis: $PASS bestanden, $FAIL Fehlschläge"
[ "$FAIL" -eq 0 ] && echo 'OK — SHA-identischer Sync + Loop-Schutz + Tags funktionieren.' \
                   || echo 'FEHLER — siehe oben.'
exit "$FAIL"
