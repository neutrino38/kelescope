# Phase 1 — Vue liveview équivalente à `kelictl monitor`

Décision d'architecture : [ADR-001](../../architecture/adr-001-connexion-kelixip.md).

## Objectif

kelescope affiche la liste des scénarios en cours sur une instance kelixip, avec les mêmes colonnes que `kelictl monitor`, et se rafraîchit automatiquement sans action de l'utilisateur. C'est le seul périmètre de la phase 1 : pas d'arrêt de scénario, pas de filtre. Ces besoins, mentionnés dans le README, sont reportés à une phase suivante.

Une seule instance kelixip est surveillée. Le multi-instance et le cluster sont hors périmètre.

## Mécanisme côté elixip

`Kelix.Control.monitor/0` (`apps/kelixip/lib/kelix/control.ex`, dépôt elixip) joint `Kelix.InstancePool.list/0` (id/pid/domain/function/script) et `SIP.Scenario.Monitor.calls/0` (state/event/command/account/medias/mediaserver/outbound) à chaque appel — un aller-retour à la demande, sans notification entre deux appels.

`Kelix.Control.subscribe_monitor/1` (dépôt elixip, branche `feat/liveview`, documenté dans `docs/design/kelixip_liveview.md` de ce dépôt) abonne un pid à ces mêmes scénarios et renvoie leur état initial, même forme que `monitor/0`. Le mécanisme : une liste d'abonnés (`MapSet(pid)`) et une notification par `send/2` dans `SIP.Scenario.Monitor` (changement de state/event/command, et fin de scénario via `clear/1`) et dans `Kelix.InstancePool` (apparition d'un scénario via `accept/4`, jointure des deux vues avant l'envoi) ; exposé via `Kelix.Control`, cohérent avec le principe que `kelictl` et l'API REST ne parlent qu'à ce module ; sur le modèle de `Kelix.Mod.Registrar.subscribe_register_event/2` (`apps/kelix_modules/lib/kelix/mod/registrar.ex`) — aucune nouvelle dépendance.

Le pid abonné reçoit ensuite, par `send/2` :
- `{:kelix_monitor, {:upsert, row}}` — apparition d'un scénario ou changement de son état/événement/commande/compte/média ; `row` porte toujours la ligne complète, mêmes colonnes que `monitor/0` ;
- `{:kelix_monitor, {:remove, id}}` — fin du scénario.

`Kelix.Control.unsubscribe_monitor/1` arrête l'abonnement ; un pid déconnecté (perte du nœud) ou mort l'arrête de lui-même.

## Composants à livrer côté kelescope

### Squelette Phoenix
`mix phx.new kelescope --no-ecto --no-mailer`. Pas de base de données ni d'envoi de mail nécessaires ; LiveView est inclus par défaut.

### Configuration de la connexion
Nom du nœud kelixip cible et cookie Erlang partagé, lus depuis l'environnement (`config/runtime.exs`), au même titre que `RELEASE_NODE` pour `kelictl`. Aucune valeur par défaut secrète committée.

### `Kelescope.Kelixip.Link` (GenServer)
- Au démarrage : `Node.set_cookie/1`, puis `Node.connect/1` vers le nœud kelixip.
- En cas de succès : appelle `Kelix.Control.subscribe_monitor(self())` par RPC. La réponse donne l'état initial (liste des scénarios en cours, même forme que `kelictl monitor`) ; l'assign démarre déjà rempli.
- Reçoit ensuite les messages poussés par kelixip et les republie localement via `Phoenix.PubSub` sur le topic `"kelixip:scenarios"`.
- Surveille la connexion (`:net_kernel.monitor_nodes(true)`) : à la perte du nœud, republie un état `:disconnected` sur le topic `"kelixip:link"` ; retente la connexion et la souscription avec un backoff, puis republie `:connected` avec un état resynchronisé.
- Un seul GenServer pour la phase 1 : pas d'abstraction multi-nœuds tant qu'un seul kelixip est surveillé.

### `KelescopeWeb.ScenarioMonitorLive`
- `mount/3` : s'abonne à `"kelixip:scenarios"` et `"kelixip:link"`, initialise les assigns `:scenarios` et `:link_status`.
- `handle_info` : met à jour `:scenarios` ou `:link_status` à chaque message reçu du `Link`.
- Gabarit : tableau avec les colonnes id/domain/function/script/account/state/event/command/medias/mediaserver/outbound (mêmes colonnes que `kelictl monitor`, `cli.ex` lignes 453-489), bandeau d'état de connexion toujours visible. Pas de formulaire, pas de bouton d'action.

## Tests

- `Kelescope.Kelixip.Link` : souscription initiale, réception de mises à jour, perte puis reprise de connexion, contre un nœud Erlang de test qui simule `Kelix.Control.subscribe_monitor/1`.
- `KelescopeWeb.ScenarioMonitorLive` (`Phoenix.LiveViewTest`) : rendu de la liste, mise à jour à réception d'un message du `Link`, affichage de la perte de connexion.

## Critères d'acceptation

- kelescope se connecte à un nœud kelixip réel (ou un nœud de test fidèle au contrat RPC) par distribution Erlang.
- La liste des scénarios affichée reprend les mêmes colonnes que `kelictl monitor`.
- La liste se met à jour dans la page sans rechargement, dès qu'un scénario apparaît, change d'état ou se termine côté kelixip — pas de sondage périodique.
- Une perte de connexion au nœud kelixip est visible dans l'interface, et la reconnexion (avec resynchronisation de l'état) est automatique.

## Hors périmètre (phase suivante)

- Arrêt d'un scénario depuis l'interface (`Kelix.Control.shutdown_scenario/1` existe déjà côté kelixip et ne demande aucun développement supplémentaire là-bas).
- Filtres sur la liste affichée.
- Plusieurs instances ou cluster kelixip.

## Risques

- Distribution Erlang à travers un réseau filtré (pare-feu, EPMD, plage de ports dynamiques) peut échouer silencieusement ; à valider tôt sur l'environnement cible réel.
- Cookie Erlang partagé = accès RPC complet au nœud kelixip, pas seulement à la lecture des scénarios (voir ADR-001). À traiter avant d'exposer kelescope au-delà d'un usage opérateur de confiance.
