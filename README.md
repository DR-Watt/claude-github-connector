# claude-github-connector

**Univerzális Claude Projekt ↔ GitHub összekötő script**

Bármely Claude projekthez futtatható interaktív bash tool, amely beállítja
a GitHub kapcsolatot: SSH kulcs, OAuth hitelesítés, repó választó TUI menü,
automatikus szinkronizálás.

---

## Gyors áttekintés

```
./gh_connect.sh
```

A script végigvezet minden lépésen — nincs szükség manuális git parancsokra
az első beállításhoz.

---

## Előfeltételek

### 1. GitHub bejelentkezés a böngészőben
A `gh auth login` megnyitja a GitHub device flow-t a terminálban.
Lépj be a GitHub fiókoddal a böngészőben **mielőtt** elindítod a scriptet.

### 2. Claude GitHub App engedély
A Claude-nak engedélyt kell adni a GitHub fiókodon belül:

```
https://github.com/apps/claude
→ Install → válaszd ki a fiókodat
→ Repository access:
   • All repositories   – minden repóhoz hozzáfér
   • Only select repos  – csak a megadottakhoz
```

Telepített appok ellenőrzése: `https://github.com/settings/installations`

### 3. SSH kulcs a GitHub-on
A script automatikusan generál egy Ed25519 SSH kulcsot (`~/.ssh/id_ed25519_github`).
Ha az automatikus feltöltés sikertelen (scope hiány), a script kiírja a publikus
kulcsot és megmutatja, hol kell kézzel feltölteni:

```
https://github.com/settings/ssh/new
→ Authentication Key → illeszd be a kulcsot → Add SSH key
```

Kapcsolat tesztelése:
```bash
ssh -T git@github.com
# Elvárt: Hi DR-Watt! You've successfully authenticated...
```

---

## Telepítés és futtatás

```bash
# Klónozás
git clone https://github.com/dr-watt/claude-github-connector
cd claude-github-connector

# Futtatható jogosultság
chmod +x gh_connect.sh

# Futtatás
./gh_connect.sh
```

---

## Mit csinál a script?

| Lépés | Művelet |
|-------|---------|
| 0 | Rendszerdiagnosztika rögzítése (log fájlba) |
| 1 | Függőségek telepítése (`git`, `gh`, `whiptail`, `jq`) |
| 2 | Előfeltétel figyelmeztetések (TUI panel) |
| 3 | GitHub CLI OAuth hitelesítés (device flow) |
| 4 | Ed25519 SSH kulcs generálás + GitHub regisztráció |
| 5 | **Interaktív repó választó** (whiptail TUI menü, összes repód) |
| 6 | Lokális Git repó inicializálás |
| 7 | `.gitignore` generálás (projekt típus szerint) |
| 8 | Remote origin SSH URL beállítása |
| 9 | Commit → Fetch → Pull → Push szinkronizálás |

---

## Log és hibakeresés

Minden futás időbélyeges log fájlt hoz létre **a script mappájában**:

```
gh_connect_20260410_110557.log        ← teljes kimenet
gh_connect_CRASH_20260410_110557.log  ← csak hiba esetén
```

Ha a script elszáll, a crash report tartalmazza:
- a hibás sort és parancsot
- a teljes call stack-et
- az utolsó 30 sor log kimenetet
- a futásidejű állapotváltozókat

```bash
# Log megtekintése:
cat gh_connect_CRASH_*.log
```

---

## SSH kulcsok helye

Az SSH kulcsok **mindig** a `~/.ssh/` könyvtárban vannak — ez az SSH protokoll
szabványa, nem változtatható. A script mappájában csak log fájlok keletkeznek.

```
~/.ssh/id_ed25519_github      ← privát kulcs (600)
~/.ssh/id_ed25519_github.pub  ← publikus kulcs (644)
~/.ssh/config                  ← SSH konfiguráció
```

---

## CI/CD pipeline

A `.github/workflows/ci.yml` automatikusan lefut minden `git push` után:

| Job | Eszköz | Mit ellenőriz |
|-----|--------|---------------|
| 🔍 ShellCheck | shellcheck | bash szintaxis és best practice |
| 🔒 Gitleaks | gitleaks | titkos kulcsok, tokenek keresése |
| 📚 Markdown Lint | — | README és dokumentáció meglétének ellenőrzése |

Ha a CI piros ❌ → a repó főoldalán látszik, mi bukott meg.

---

## Manuális frissítés workflow

Ha a `gh_connect.sh` új verziót kapsz:

```bash
# Fájl cseréje
cp ~/Downloads/gh_connect.sh ./gh_connect.sh

# Git szinkronizálás
git add gh_connect.sh
git commit -m "fix: gh_connect.sh frissítés"
git push
```

---

## Ismert korlátok

| Korlát | Magyarázat |
|--------|-----------|
| `gh ssh-key add` WARN | A `gh` token alapértelmezetten nem tartalmaz `write:public_key` scope-t — ez normális, az SSH teszt dönti el, hogy a kulcs fent van-e |
| Claude.ai webes push | Az Anthropic GitHub MCP integrációja csak olvasást enged — push csak a lokális Linux rendszerből működik |
| Email scope | Ha a GitHub fiókban az email privát, a script kézzel kéri be |

---

## Függőségek

| Eszköz | Csomag | Leírás |
|--------|--------|--------|
| `git` | git | verziókezelés |
| `gh` | github-cli | GitHub CLI (automatikusan települ) |
| `whiptail` | whiptail | interaktív TUI menü |
| `ssh-keygen` | openssh-client | SSH kulcs generálás |
| `curl`, `jq` | curl, jq | API lekérések és JSON feldolgozás |

---

## Dokumentáció

- GitHub CLI: https://cli.github.com/manual/
- Whiptail: https://whiptail.readthedocs.io/en/latest/
- GitHub Apps: https://docs.github.com/en/apps
- GitHub SSH: https://docs.github.com/en/authentication
- ShellCheck: https://www.shellcheck.net/
- Gitleaks: https://github.com/gitleaks/gitleaks

---

## Verzió

`v1.0.0` — 2026-04-10

Szerző: dr-watt | Repó: https://github.com/dr-watt/claude-github-connector
