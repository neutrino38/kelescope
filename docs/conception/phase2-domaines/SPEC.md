# Phase 2 (début) — Domaines : liste, détail, rechargement des scénarios, filtre par domaine

## Objectif

kelescope affiche la liste des domaines servis par l'instance kelixip surveillée, avec les compteurs d'appels actifs et d'enregistrements mis à jour en direct. Un clic sur un domaine déplie son détail (configuration, fonctions activées, plan de numérotation) juste sous sa ligne — un seul domaine déplié à la fois. Un clic sur le nombre d'enregistrements déplie la liste des enregistrements SIP du domaine, groupée par AOR. Un bouton recharge les scénarios (scripts) d'un domaine sans redémarrer le nœud. L'écran des scénarios en cours (phase 1) gagne un filtre par domaine.

Une seule instance kelixip, comme en phase 1 : pas de multi-instance ni de cluster.

## Mécanisme côté elixip

Ces fonctions de `Kelix.Control` (dépôt elixip, `apps/kelixip/lib/kelix/control.ex`) existaient déjà :

- `domains/0` — tous les domaines servis et leurs propriétés (`kelictl domain list`), dans l'ordre de `domains.toml` (significatif : le plan de numérotation est premier-trouvé-premier-servi). Chaque ligne est la même forme complète que `domain/1` — configuration (`aliases`, `max_calls`, fonctions activées, `registrar`/`presence` avec leur script, plan de numérotation ordonné) et compteurs en direct (`active_calls`, `registrations`) : la liste porte déjà tout ce qu'il faut pour l'affichage déplié, sans second aller-retour au clic.
- `domain/1` — un domaine par nom ou alias, insensible à la casse ; utilisé après un rechargement pour rafraîchir la seule entrée concernée (version/obsolescence des scripts).
- `reload_script/2` — recharge un ou plusieurs scripts par nom. Retourne `%{nom => :ok | {:error, raison}}`.
- `registrations/1` — les enregistrements d'un domaine (`kelictl registration list <domaine>`), une entrée par AOR avec ses contacts.

Une fonction a été ajoutée pour cette phase, sur le modèle de `subscribe_monitor/1` (phase 1) :

- `subscribe_domain_counters/1` (et `unsubscribe_domain_counters/1`) — souscrit `pid` aux changements de compteurs par domaine. Combine deux sources internes à kelixip : `Kelix.InstancePool` pour `active_calls` (déjà tenu à jour à chaque apparition/fin d'instance) et `Kelix.Mod.Registrar` pour `registrations` (à chaque enregistrement/désenregistrement/expiration), chacune avec sa propre liste d'abonnés. Le pid abonné reçoit `{:kelix_domain_counter, domaine, :active_calls | :registrations, compte}` à chaque changement, et récupère l'état initial (forme de `domains/0`) en retour de l'appel — même contrat que `subscribe_monitor/1`. Décision et détails : `docs/design/kelixip_liveview.md` (dépôt elixip), section « Domain counters push ».

Ce mécanisme réutilise la connexion Erlang distribuée déjà établie en phase 1 ([ADR-001](../../architecture/adr-001-connexion-kelixip.md)) ; aucune nouvelle décision d'architecture n'est nécessaire côté kelescope.

## Composants livrés côté kelescope

### `Kelescope.Kelixip.Control`
Fonctions RPC ajoutées, même forme que `status/1` : `list_domains/1`, `domain/2`, `reload_scripts/2`, `registrations/2`, `subscribe_domain_counters/2`.

### `Kelescope.Kelixip.Link`
Accesseur `target_node/1` : les autres modules RPC vers le même nœud que le `Link`, sans dupliquer sa configuration (`KELIXIP_NODE`/`KELIXIP_COOKIE`).

### `Kelescope.Kelixip.DomainsLink` (GenServer)
Une seconde connexion au nœud kelixip surveillé (même nœud que `Link`, sa propre souscription), sur le modèle exact de `Link` : se connecte, appelle `subscribe_domain_counters/1`, republie l'état initial et chaque changement via `Phoenix.PubSub` sur `"kelixip:domains"` (compteurs) et `"kelixip:domains_link"` (état de connexion), retente avec un backoff en cas de perte. Garde le dernier état connu (liste des domaines dans l'ordre de `domains.toml`, mise à jour par nom à chaque poussée) pour qu'un montage après la connexion initiale n'attende pas la prochaine poussée.

Une connexion dédiée plutôt qu'un canal de plus sur `Link` : même choix déjà fait pour `StatusPoller`, chaque flux RPC est un processus autonome.

### `KelescopeWeb.DomainListLive` (`/domains`)
Liste des domaines avec leurs compteurs, mise à jour par bandeau de connexion (`"kelixip:domains_link"`) et par poussée de compteur (`"kelixip:domains"`), sans sondage. Un bouton « Rafraîchir » relit `domains/0` pour tout le reste (configuration, alias…), qui n'est pas poussé.

Chaque ligne se déplie indépendamment sur deux axes, tous deux au clic :
- le **nom du domaine** déplie son détail (registrar/presence/plan de numérotation/bouton de rechargement) — un seul domaine déplié à la fois, ouvrir un autre domaine referme le précédent ;
- le **nombre d'enregistrements** déplie la liste des enregistrements SIP du domaine (`registrations/1`), un bloc par AOR listant ses contacts (URI, expiration, source, transport, instance) — même règle, un seul à la fois.

Rechargement des scénarios : recharge tous les scripts référencés par le domaine déplié (`registrar`, `presence`, chaque règle du plan de numérotation, dédupliqués), affiche le résultat par script, puis relit ce seul domaine (`domain/2`) pour rafraîchir version/obsolescence.

### `KelescopeWeb.ScenarioMonitorLive` (`/`)
Filtre par domaine : un `<select>` au-dessus du tableau, rempli des domaines actuellement présents dans les scénarios affichés (pas d'appel RPC supplémentaire) ; sélectionner un domaine filtre les lignes, côté LiveView, sans changer ce que `Link` republie.

### Double de développement (`dev_support/kelix_control_stub.ex`)
Deux domaines factices (`example.com` avec alias, plan de numérotation à deux règles, deux AOR enregistrés, et `test.local` minimal, sans enregistrement) ; `reload_script/2` simule un échec pour `fallback.exs` afin d'exercer l'affichage d'erreur ; `push_counter/1` pousse un compteur à la demande (tests).

## Tests

- `Kelescope.Kelixip.DomainsLinkTest` : souscription initiale, réception d'une mise à jour de compteur, perte puis reprise de connexion — même structure que `LinkTest`.
- `KelescopeWeb.DomainListLiveTest` : rendu de la liste, rafraîchissement, dépliage/repliement du détail d'un domaine (un seul à la fois), rechargement des scripts avec un résultat par script, dépliage des enregistrements groupés par AOR (domaine vide inclus), répercussion d'une poussée de compteur sans rafraîchissement manuel.
- `KelescopeWeb.ScenarioMonitorLiveTest` : (existant) rendu, mises à jour poussées — le filtre par domaine est exercé manuellement (rendu du `<select>`, pas encore de test dédié à la sélection).

## Critères d'acceptation

- La liste des domaines reprend les mêmes colonnes que `kelictl domain list`, mises à jour sans rechargement de page quand un compteur change.
- Le détail d'un domaine reprend les mêmes informations que `kelictl domain show <nom>` ; un seul domaine déplié à la fois.
- Les enregistrements affichés reprennent `kelictl registration list <domaine>`, groupés par AOR.
- Un rechargement des scénarios d'un domaine appelle `reload_script/2` avec exactement les scripts référencés par ce domaine.
- Le filtre par domaine sur l'écran des scénarios ne masque que l'affichage : les données sous-jacentes ne changent pas.
- Une erreur RPC ou un domaine inconnu affiche un message, jamais un crash de la page.

## Hors périmètre (reste de la phase 2)

- Pool de mediaservers, retrait d'un AOR, état de connexion DB, arrêt d'un scénario : traités dans [phase2-monitoring-actions](../phase2-monitoring-actions/SPEC.md), pas ici.
- Rechargement de `domains.toml` lui-même (`reload_domains/0`, `reload_all/0`) : ajout de domaine ou changement de configuration, pas seulement de script.
- Notification des instances en cours lors d'un rechargement de script (`notify?` existe côté elixip mais n'est pas encore implémenté).

## Risques

- `reload_script/2` ne garantit pas qu'une instance déjà en cours sur l'ancienne version du script soit prévenue ; documenté côté elixip comme raffinement à venir, pas une régression de kelescope.
- `DomainsLink` double la connexion Erlang déjà ouverte par `Link` vers le même nœud (une souscription de plus, pas un second cookie ni un second réseau) : accepté pour rester cohérent avec `StatusPoller`, à revisiter si le nombre de connexions par nœud devient un souci.
