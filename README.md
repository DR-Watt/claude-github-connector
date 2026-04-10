# claude-github-connector

**Univerzális Claude Projekt ↔ GitHub összekötő script**

Bármely Claude projekthez futtatható interaktív bash tool, amely beállítja
a GitHub kapcsolatot: SSH kulcs, OAuth hitelesítés, repó választó TUI menü.

---

## Előfeltételek

A script futtatása **előtt** ellenőrizd:

### 1. Böngésző session
A `gh auth login` megnyitja az alapértelmezett böngészőt OAuth hitelesítéshez.
Lépj be a GitHub fiókoddal a böngészőben mielőtt elindítod a scriptet.

### 2. Claude GitHub App engedély
A Claude-nak engedélyt kell adni a GitHub fiókodon belül:

```
https://github.com/apps/claude
→ Install → válaszd ki a fiókodat
→ Repository access:
   • All repositories   – minden repóhoz hozzáfér
   • Only select repos  – csak a megadottakhoz
```

Telepített appok: `https://github.com/settings/installations`

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
| 0 | Függőségek telepítése (`git`, `gh`, `whiptail`, `jq`) |
| 1 | Előfeltétel figyelmeztetések (TUI panel) |
| 2 | GitHub CLI OAuth hitelesítés (böngésző) |
| 3 | Ed25519 SSH kulcs generálás + GitHub regisztráció |
| 4 | **Interaktív repó választó** (whiptail TUI menü, összes repód) |
| 5 | Lokális Git repó inicializálás |
| 6 | `.gitignore` generálás (projekt típus szerint) |
| 7 | Remote origin SSH URL beállítása |
| 8 | Fetch → pull → commit → push szinkronizálás |

---

## Dokumentáció

- GitHub CLI: https://cli.github.com/manual/
- Whiptail: https://whiptail.readthedocs.io/en/latest/
- GitHub Apps: https://docs.github.com/en/apps
- GitHub SSH: https://docs.github.com/en/authentication
