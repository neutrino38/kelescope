# Phase 2 (début) — Domaines : liste, détail, rechargement des scénarios

## Objectif

kelescope affiche la liste des domaines servis par l'instance kelixip surveillée, permet de consulter le détail de chacun (configuration, fonctions activées, plan de numérotation, compteurs en direct) et de recharger les scénarios (scripts) d'un domaine sans redémarrer le nœud.

Une seule instance kelixip, comme en phase 1 : pas de multi-instance ni de cluster.

## Mécanisme côté elixip

Contrairement à `subscribe_monitor/1` en phase 1, ces fonctions existent déjà dans `Kelix.Control` (dépôt elixip, branche `master`, `apps/kelixip/lib/kelix/control.ex`) : aucun développement côté elixip n'est nécessaire.

- `Kelix.Control.domains/0` — tous les domaines servis et leurs propriétés (`kelictl domain list`), dans l'ordre de `domains.toml` (significatif : le plan de numérotation est premier-trouvé-premier-servi). Chaque ligne est la même forme que `domain/1`.
- `Kelix.Control.domain/1` — un domaine (`kelictl domain show <nom>`), trouvé par nom ou par alias, insensible à la casse. `{:error, :not_found}` sinon. Porte la configuration (`aliases`, `max_calls`, fonctions activées, `registrar`/`presence` avec leur script, plan de numérotation ordonné avec pattern/script/défaut) et les compteurs en direct (`active_calls`, `registrations`).
- `Kelix.Control.reload_script/2` — recharge un ou plusieurs scripts par nom (`kelictl reload-script <nom…>`). Retourne `%{nom => :ok | {:error, raison}}`, une entrée par script.

Aucune souscription : contrairement au flux de scénarios (phase 1), il n'existe pas de mécanisme de notification quand un domaine change — kelescope lit à la demande.

Ce mécanisme réutilise la connexion Erlang distribuée déjà établie en phase 1 ([ADR-001](../../architecture/adr-001-connexion-kelixip.md)) ; aucune nouvelle décision d'architecture n'est nécessaire.

## Composants livrés côté kelescope

### `Kelescope.Kelixip.Control`
Trois fonctions RPC ajoutées, même forme que `status/1` : `list_domains/1`, `domain/2`, `reload_scripts/2` (nom pluriel côté kelescope, la fonction distante `reload_script/2` prenant déjà une liste).

### `Kelescope.Kelixip.Link`
Accesseur `target_node/1` ajouté : les deux nouvelles LiveViews doivent RPC vers le même nœud que le `Link`, sans dupliquer sa configuration (`KELIXIP_NODE`/`KELIXIP_COOKIE`).

### `KelescopeWeb.DomainListLive` (`/domains`)
Liste des domaines (nom, alias, fonctions, appels max, appels actifs, enregistrements), lien vers le détail de chacun. Un bouton « Rafraîchir » relit `domains/0` — pas de mise à jour automatique, cette donnée n'est pas poussée.

### `KelescopeWeb.DomainShowLive` (`/domains/:name`)
Détail d'un domaine : alias, compteurs, configuration `registrar`/`presence` (script, module chargé, version, obsolescence), plan de numérotation. Bouton « Recharger les scénarios du domaine » : recharge tous les scripts référencés par ce domaine (`registrar`, `presence`, chaque règle du plan de numérotation, dédupliqués), affiche le résultat par script, puis relit le domaine pour rafraîchir version/obsolescence après rechargement.

### Double de développement (`dev_support/kelix_control_stub.ex`)
Deux domaines factices (`example.com` avec alias, plan de numérotation à deux règles, et `test.local` minimal) ; `reload_script/2` simule un échec pour `fallback.exs` afin d'exercer l'affichage d'erreur.

## Tests

- `KelescopeWeb.DomainListLiveTest` : rendu de la liste, lien vers le détail, rafraîchissement.
- `KelescopeWeb.DomainShowLiveTest` : rendu du détail (configuration, plan de numérotation), rechargement des scripts avec un résultat par script (succès et échec), domaine inconnu affiché sans crash.

## Critères d'acceptation

- La liste des domaines reprend les mêmes colonnes que `kelictl domain list`.
- Le détail d'un domaine reprend les mêmes informations que `kelictl domain show <nom>`.
- Un rechargement des scénarios d'un domaine appelle `reload_script/2` avec exactement les scripts référencés par ce domaine, sans notification manquante ni doublon.
- Un domaine inconnu ou une erreur RPC affiche un message, jamais un crash de la page.

## Hors périmètre (reste de la phase 2)

- Pool de mediaservers, vue des enregistrements, retrait d'un AOR, état de connexion DB, arrêt d'un scénario, filtres sur le monitor : autres items du README, non traités ici.
- Rechargement de `domains.toml` lui-même (`reload_domains/0`, `reload_all/0`) : ajout de domaine ou changement de configuration, pas seulement de script. Resterait à faire si le besoin apparaît.
- Notification des instances en cours lors d'un rechargement de script (`notify?` existe côté elixip mais n'est pas encore implémenté : voir le commentaire sur `reload_script/2`).

## Risques

- `reload_script/2` ne garantit pas qu'une instance déjà en cours sur l'ancienne version du script soit prévenue ; documenté côté elixip comme raffinement à venir, pas une régression de kelescope.
