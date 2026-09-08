# ADR-002 : Découpage du paquet RPM en socle et applications chargées

## Statut
Accepté. L'invariant sur les traductions est amendé par
[ADR-003](adr-003-backend-gettext-par-partie.md) : chaque partie porte son
propre backend Gettext et son propre catalogue.

## Contexte

Le paquet `kelescope` installe une release Elixir autonome dans `/opt/kelescope`.
Mesures relevées sur `kelescope-0.1.1-1.el9.x86_64.rpm` :

| Contenu | Taille |
|---|---|
| Release installée `/opt/kelescope` | 19 Mo (RPM : 7,6 Mo) |
| ERTS et les 34 dépendances | ~18,4 Mo |
| Application `kelescope` | 548 Ko |
| — dont `ebin` (les modules du projet) | 121 Ko |
| — dont `priv` (assets JS et CSS, gettext) | 427 Ko |
| Un module de page (`ScenarioMonitorLive.beam`) | 14 Ko |

Le poids d'une livraison ne vient donc pas du code de kelescope. Il vient du
runtime. Corriger une ligne dans une page expédie 7,6 Mo.

Deux besoins motivent un découpage. Livrer léger, d'abord. Mettre à jour une
partie de l'interface sans couper le service, ensuite.

Sur ce second point, le gain réel est modeste. Un `systemctl restart kelescope`
coupe le service deux à cinq secondes. LiveView reconnecte seul et remonte la
page. L'utilisateur voit un clignotement, pas une erreur. Le rechargement à
chaud supprime ce clignotement et n'interrompt pas une action en cours.

### La contrainte du boot script

Le boot script de la release fige la liste des modules de chaque application.
Extrait de `releases/0.1.1/start.script` :

```
{path, ["…/consolidated", "$RELEASE_LIB/kelescope-0.1.1/ebin"]},
{primLoad, ['Elixir.Kelescope','Elixir.Kelescope.Application', … ]},
```

`primLoad` est la directive qui précharge des modules au démarrage du nœud. La
release tourne en mode `embedded`, où aucun module ne se charge à la demande.
Deux conséquences en découlent. Un module ajouté par une mise à jour n'est pas
préchargé, et reste introuvable (`undef`). Un module supprimé fait échouer le
`primLoad`, donc le démarrage du nœud.

L'option `:none` de `mix release` ne résout pas ce point : `kelescope.rel`
déclare `{iex,"1.18.3",none}` et `iex` est quand même préchargé.

Tant qu'une application figure dans le boot script, elle n'est pas remplaçable
indépendamment du reste.

### Autres couplages relevés

- La consolidation de protocoles est globale (`releases/0.1.1/consolidated`).
  Aucun module du projet ne fait de `defimpl` aujourd'hui.
- Tailwind produit un `app.css` unique en scannant tous les templates.
  `phx.digest` produit un `cache_manifest.json` unique.
- Un backend Gettext compile les traductions qu'il sert.
- `sys.config` et `runtime.exs` portent la configuration de toutes les parties.
- `Kelescope.Application` démarre les quatre processus kelixip.
- Le routeur ne dépend pas des modules qu'il route. `live "/mcu", McuLive` ne
  stocke qu'un atome, résolu à l'exécution.

## Décision

Le paquet est découpé en un **socle runtime** et plusieurs **applications OTP**
installées hors de la release et chargées au démarrage.

L'application principale de la release devient `kelescope_boot`, un chargeur.
Les applications de kelescope ne figurent plus dans le `.rel`. Elles sont
installées dans `/opt/kelescope/plugins/<application>-<abi>/ebin`, et le
chargeur les ajoute au code path, les charge, puis les démarre.

Quatre applications, alignées sur les frontières déjà présentes dans le code :

| Application | Contenu |
|---|---|
| `kelescope_core` | Endpoint, Router, Layouts, CoreComponents, Gettext, Telemetry, Error\*, Locale\*, `Kelixip.Link`, `Kelixip.DomainsLink`, tous les assets |
| `kelescope_monitor` | `ScenarioMonitorLive`, `StatusPoller` |
| `kelescope_domaines` | `DomainListLive` |
| `kelescope_mcu` | `McuLive`, `ConferencesPoller` |

Les versions OTP de ces applications sont **figées**. Elles valent un numéro
d'ABI, c'est-à-dire un numéro de contrat interne entre le socle et les parties.
Il ne bouge qu'à une rupture de ce contrat. La version produit vit uniquement
dans le champ `Version` du RPM.

Un seul dépôt et un seul fichier spec produisent tous les sous-paquets. Les
parties sont donc construites ensemble, et cohérentes par construction. Elles
se déploient séparément, avec un `Requires: kelescope-core >= <version
minimale>` et jamais une égalité stricte.

Le rechargement à chaud se fait par rechargement de modules, déclenché en
`%posttrans`, avec repli sur un redémarrage du service.

### Options écartées

**Les mises à jour OTP `appup` et `relup`.** C'est le seul mécanisme qui migre
l'état des processus en place. `mix release` ne sait pas générer de `relup`, et
l'outil qui le portait n'est plus maintenu. Il faudrait écrire ces fichiers à la
main, à chaque version, sur une application Phoenix. Coût sans rapport avec le
gain.

**Découper les `.beam` d'une seule application OTP entre plusieurs RPM.**
`kelescope.app` et le boot script énumèrent la liste des modules. Toute
addition ou suppression de module dans un satellite impose de reconstruire le
socle, et verrouille les satellites à la version exacte du socle. Le découpage
existerait sur le papier, pas dans les faits.

**Un dépôt et un fichier spec par partie.** Cette voie donne une vraie
indépendance de version et de cadence. Elle exige que le socle devienne une
dépendance de build, une API publique stable et documentée, et une chaîne
d'intégration par satellite. Elle ne se justifie que si des équipes distinctes
livrent à des rythmes distincts, ce qui n'est pas le cas.

**Deux instances derrière un reverse proxy.** Cette voie répond à un besoin de
disponibilité continue, pas au besoin de livraison légère. Elle ne préserve pas
davantage les sessions LiveView qu'un redémarrage.

## Conséquences

- Une livraison passe de 7,6 Mo à environ 250 Ko pour le socle applicatif, et à
  quelques dizaines de kilo-octets pour une partie.
- Le paquet runtime ne change que si ERTS, une dépendance ou la configuration
  compile-time change.
- Rien ne change pour l'exploitant. `bin/kelescope`, `/opt/kelescope`, l'unité
  systemd et `/etc/kelescope/kelescope.env` restent identiques.
- **Le numéro de version du RPM ne décrit plus ce qui tourne.** Une commande
  doit afficher la version réellement chargée de chaque partie. Sans elle, le
  diagnostic en production devient impossible.
- Aucune partie hors du socle ne peut définir de `defimpl`. La consolidation de
  protocoles vit dans le paquet runtime.
- Les assets et les routes restent dans le socle. Un changement de style ou une
  route nouvelle impose donc une livraison du socle. Un changement de logique,
  de rendu ou de texte dans une page existante n'en impose pas.
- Une classe utilitaire employée par une partie mais absente du CSS du socle ne
  produit aucune erreur. Elle produit un affichage faux. Ce risque est le plus
  discret du lot.
- Une partie ne peut pas définir de configuration compile-time. Ses réglages
  passent par les valeurs par défaut de son propre fichier `.app`, surchargées
  par des variables lues dans `kelescope.env`.
- Les processus kelixip quittent `Kelescope.Application` pour le superviseur de
  leur partie. C'est ce qui rend l'arrêt et le redémarrage d'une partie
  possibles sans toucher au reste.
- Un LiveView déjà ouvert dont les `assigns` ne correspondent plus à la nouvelle
  version du module plante, et le client remonte la page. Le comportement
  observé est alors celui d'un redémarrage, pour un seul onglet.
- Le mode `embedded` est conservé. Le chargeur charge donc explicitement chaque
  module listé dans le `.app` d'une partie. Aucun chargement paresseux, donc
  aucun `undef` découvert des heures après la mise à jour.

Détails d'implémentation : [docs/conception/decoupage-rpm/SPEC.md](../conception/decoupage-rpm/SPEC.md)
