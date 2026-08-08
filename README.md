# gitchorus

> Bidirektionaler, SHA-identischer Git-Sync zwischen **GitHub** und **GitLab**.

Zwei Plattformen, eine Wahrheit: Dieses Repo wird von GitHub und GitLab
**exakt identisch** gespiegelt — gleiche Commits, gleiche SHAs, gleiche Tags,
gleiche Releases. Ein Push auf `main` (oder ein neuer Tag) auf der einen
Seite erscheint automatisch auf der anderen. Du musst nie beide Seiten
ansehen — sie sind jederzeit synchron.

[GitHub](https://github.com/unikat-cloud/gitchorus) ·
[GitLab](https://gitlab.unikat-cloud.de/unikat-cloud.gitlab/gitchorus)

## Wie es funktioniert

Ein Push auf `main` (oder ein Tag) löst auf der jeweiligen Seite eine
Pipeline aus, die den Push auf die Gegenseite spiegelt:

```
Push auf GitHub ──► GitHub Actions ──► git push → GitLab
                                          │
                                          ▼
                               GitLab CI (Echo-Push)
                                          │
                              SHA-Check: Commits bereits auf GitHub?
                                          │
                                          ├─ Ja → Skip (keine Schleife)
                                          └─ Nein → (nur bei echtem Neu-Push)
```

### Warum die CI-Dateien auf beiden Seiten liegen

Damit beide Repos **SHA-identisch** sind, liegen `.gitlab-ci.yml` und
`.github/` auf **beiden** Plattformen. Das ist harmlos: GitHub ignoriert
`.gitlab-ci.yml` und GitLab ignoriert `.github/` — jede Plattform führt nur
ihre eigene CI aus. Durch die identischen Commits braucht der Sync kein
Umschreiben (kein History-Rewrite), Tags und Releases funktionieren überall
gleich.

### Schleifen-Schutz (Kernstück)

Ein gespiegelter Push enthält **exakt dieselben Commit-SHAs** wie der
Ursprungs-Push. Das Skript `scripts/git-sync.sh` prüft deshalb vor dem Push,
ob **alle** neuen Commits des Pushes bereits auf der Gegenseite existieren:

- Existieren sie → es ist unser eigener Echo-Push → **Skip**
- Existieren sie nicht → echter neuer Push → spiegeln
- Tags werden zusätzlich geprüft: fehlt ein Tag auf der Gegenseite, wird er
  auch dann gespiegelt, wenn seine Commits bereits dort liegen

Dadurch entsteht pro Änderung maximal **1** Spiegel-Push je Seite — niemals
eine Endlosschleife. Der Check ist SHA-basiert (nicht Author-/Bot-basiert),
weil die Commits beim Spiegeln ihre ursprünglichen Autoren behalten.

Zusätzlich wird **ohne `--force`** gepusht: Gleichzeitige Pushes auf beiden
Seiten führen zu einem sichtbaren `rejected` (Pipeline wird rot) statt zu
stillem Datenverlust. Tokens werden nie in Logs ausgegeben.

## Dateien

| Datei | Zweck |
|---|---|
| `scripts/git-sync.sh` | Gemeinsames Sync-Skript (identisch auf beiden Seiten) |
| `.gitlab-ci.yml` | GitLab-Seite: spiegelt `main` + Tags → GitHub |
| `.github/workflows/gitlab-sync.yml` | GitHub-Seite: spiegelt `main` + Tags → GitLab |
| `test/sandbox-sync.sh` | Lokaler Test für Sync, Loop-Schutz und Tags |
| `LICENSE` | MIT-Lizenz |

## Issues & PRs

Issues und Pull/Merge Requests bitte **nur auf GitHub** melden:

**[github.com/unikat-cloud/gitchorus/issues](https://github.com/unikat-cloud/gitchorus/issues)**

Das GitLab-Repo ist ein Code-Spiegel (für Doku, Download und Mirror-Verfügbarkeit)
— es wird aber nicht separat verwaltet.

## Setup (für weitere Repos)

Die beiden CI-Dateien + das Skript sind **repo-agnostisch** (URLs und Tokens
kommen aus CI-Variablen). Für ein weiteres Repo (z.B. `chartsense`) genügt:

1. `scripts/git-sync.sh`, `.gitlab-ci.yml` und den Actions-Workflow hinein­kopieren
2. **GitLab → GitHub** (*Settings → CI/CD → Variables*):
   - `GITHUB_REMOTE_URL` = `https://github.com/<org>/<repo>.git`
   - `GITHUB_SYNC_TOKEN` = GitHub fine-grained PAT (`Contents: Read and write`,
     als **Masked** + **Protected** markieren)
3. **GitHub → GitLab** (*Settings → Secrets and variables → Actions*):
   - **Variable** `GITLAB_REMOTE_URL` = `https://gitlab.../<group>/<repo>.git`
   - **Secret** `GITLAB_SYNC_TOKEN` = GitLab PAT (Scopes
     `read_repository` + `write_repository`)
4. Auf einer Seite pushen — der Sync übernimmt den Rest.

Wichtig: Die CI-Dateien müssen auf **beiden** Seiten liegen, damit die
Repos SHA-identisch bleiben (einmal über den Sync verteilen, dann immer
aktuell halten).

## Test

- **Lokal:** `bash test/sandbox-sync.sh` — simuliert beide Richtungen inkl.
  Loop-Schutz und Tag-Sync mit zwei Bare-Repositories (14 Szenarien).
- **Live:** Auf einer Seite eine Änderung pushen → in beiden Pipelines
  prüfen: genau **ein** Sync-Lauf pro Seite, der zweite endet mit
  `Echo-Push erkannt … Skip`.

## Lizenz

[MIT](LICENSE) © 2026 [Unikat-Cloud](https://github.com/unikat-cloud)
