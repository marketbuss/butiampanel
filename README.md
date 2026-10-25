# butiampanel

Mod menu Roblox **adaptatif** : un seul fichier Lua, n'importe quel jeu.
Le panel detecte le jeu au chargement, choisit un profil, scanne les remotes
et branche les modules dessus. Ce qui n'est pas connu du panel reste utilisable
via les modules universels + l'explorateur de remotes.

Fichier : `butiampanel.lua` (2699 lignes, ~88 Ko)

---

## Execution

Coller le contenu de `butiampanel.lua` dans l'executeur, ou :

```lua
-- fichier copie dans le workspace de l'executeur
loadstring(readfile("butiampanel.lua"))()

-- ou heberge quelque part
loadstring(game:HttpGet("https://ton.host/butiampanel.lua"))()
```

Re-executer le script decharge l'instance precedente avant d'ouvrir la nouvelle :
pas de panels empiles.

Executeurs testes pour les API : Delta, Fluxus, Codex, Arceus, Wave, Synapse.
Sans `Drawing`, l'ESP retombe sur `Highlight` + `BillboardGui`.
Sans `writefile`, la config reste en memoire pour la session.

---

## Touches

| Touche | Action |
|---|---|
| `RightShift` | ouvrir / fermer le menu (rebindable) |
| `E` | maintenir pour l'aimbot (rebindable) |
| `WASD` + `Espace` / `Ctrl` | fly, relatif a la camera |

---

## Onglets

**Joueur** — vitesse, saut, fly (LinearVelocity + PlatformStand), noclip,
saut infini, anti-AFK.

**Combat** — aimbot camera (FOV en pixels, lissage, check murs par raycast,
check equipe, cible Head / HRP / UpperTorso), extension de hitbox.

**Visuel** — ESP boites / noms / vie / distance / tracantes / chams,
fullbright, suppression du brouillard, FOV camera, heure.

**Teleport** — liste des joueurs, teleport sous la souris, points nommes
enregistres par jeu (position sauvegardee dans le profil).

**Farm** — scan des remotes, dropdown classe, arguments types, tir unique,
boucle auto avec cadence, auto-clic VirtualUser.

**Jeu** — PlaceId / GameId / executeur / Drawing / equipes / nombre de remotes,
relance de la detection, export du profil courant en Lua (presse-papiers).

**Config** — rebind du menu, sauvegarde / chargement / reset, rejoin,
nouveau serveur, copie du JobId, cap FPS, dechargement.

---

## Comment il s'adapte

1. **Fingerprint** — `PlaceId`, `GameId`, nom via `MarketplaceService:GetProductInfo`.
2. **Profil** — correspondance par `PlaceId`, sinon par mot-cle du nom
   (`SEEDS`, section 4 du fichier), sinon profil `Universal`.
3. **Reglages** — le profil impose des valeurs de depart : vitesse, saut,
   portee ESP, check equipe (auto si le jeu a des equipes).
4. **Remotes** — parcours en largeur borne (15 000 instances) de
   `ReplicatedStorage` + `ReplicatedFirst` ; chaque remote est classe
   `farm` / `economy` / `combat` / `social` / `autre` par mots-cles, trie
   farm-first, et expose dans le dropdown (300 entrees max pour l'UI).
5. **Memoire** — les points et les remotes decouverts sont ecrits dans
   `butiampanel/config.lua` et recharges au prochain join sur ce jeu.

### Ajouter un jeu

Deux methodes.

**Auto** — joue une fois, ouvre `Jeu` > `Copier le profil Lua`, colle le bloc
dans `SEEDS` (section 4) du fichier. Le bloc contient deja le PlaceId, le nom,
les valeurs courantes et les remotes classes.

**Manuel** :

```lua
[1234567890] = {
    name = "Mon Jeu",
    keywords = { "mon jeu" },          -- secours si le PlaceId change
    defaults = { walk = 24, jump = 55, espDistance = 1200, teamCheck = false },
    notes = "Plant / harvest / sell.",
},
```

---

## Arguments des remotes

Le champ `Arguments` accepte une liste separee par virgules :

```
1, true, "hello world", nil, -4.5
```

- nombres -> number
- `true` / `false` -> boolean
- `"texte"` ou `'texte'` -> string entre guillemets
- `nil` -> trou conserve dans la liste (l'index est respecte)
- tout le reste -> string brute

La virgule dans une chaine entre guillemets n'est pas geree : pour ce cas,
passe par un remote qui prend un seul argument.

---

## Config sur disque

```
butiampanel/config.lua     -- "return {flags = {...}, games = {...}}"
```

- `flags` : une entree par controle, rechargee au demarrage.
- `games[placeId]` : `name`, `points`, `remotes`.
- `Reset la config` supprime le fichier.

---

## Notes techniques

- Un seul `Heartbeat` dispatche les modules (cadences 0,05 s a 0,5 s) : pas
  de dizaines de boucles concurrentes.
- Tous les callbacks de boucle sont sous `pcall` : une frame qui casse ne tue
  pas le panel.
- `Table 3D -> ecran` : projection des 8 coins de `Model:GetBoundingBox()`.
  Si moins de 3 coins sont visibles, la frame d'ESP est masquee.
- Aimbot : cible la plus proche du centre ecran dans le rayon FOV, raycast
  de verification, lissage exponentiel (`1 - exp(-dt / smooth)`).
- Nettoyage complet au dechargement : fly, aim, ESP, lumiere, FOV, taille du
  HRP, connexions, GUI.
- Les ecritures sont des `FireServer` / `InvokeServer` sur les remotes du jeu :
  ce que le serveur accepte est la seule limite cote serveur.
