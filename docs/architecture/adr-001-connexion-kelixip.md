# ADR-001 : Connexion de kelescope à kelixip

## Statut
Accepté

## Contexte
kelescope doit se comporter comme `kelictl`, avec une interface web à la place d'un CLI. Le dépôt elixip (branche `release/1.5.1`) documente déjà cette UI dans `docs/design/kelixip_liveview.md` : application Phoenix séparée, sa propre release, ne dépendant pas de `:elixip2`, connectée à kelixip par le réseau. C'est ce document, et non `liveview-adapter.md` (qui vise un pont direct scénario ⟷ LiveView pour des usages interactifs comme un webphone), qui décrit l'architecture pertinente pour kelescope.

`kelictl monitor` interroge l'état des scénarios à la demande (photo instantanée), via RPC vers `Kelix.Control` (`Kelix.Control.monitor/0`, `apps/kelixip/lib/kelix/control.ex`). kelescope vise en plus un rafraîchissement automatique, sans interroger kelixip en boucle. Une fois deux nœuds Erlang connectés (même cookie), kelixip peut envoyer un message directement à un process de kelescope dès qu'un scénario change d'état, sans sondage. L'API REST documentée (`GET /scenarios`, port 8090) ne le permettrait qu'au prix d'un sondage ou d'un flux additionnel (SSE, websocket) qui n'existe pas côté kelixip aujourd'hui.

## Décision
kelescope se connecte à kelixip par le pont Erlang distribué : même cookie que `kelictl`, appels RPC vers `Kelix.Control` pour les lectures. Pour le rafraîchissement automatique, kelescope s'abonne au flux de scénarios plutôt que de le sonder : kelixip pousse les changements d'état vers kelescope dès qu'ils se produisent.

Ce mécanisme de souscription existe côté kelixip (dépôt elixip, branche `feat/liveview`) : une liste d'abonnés (`send/2`) dans `SIP.Scenario.Monitor` et dans `Kelix.InstancePool`, exposée via `Kelix.Control.subscribe_monitor/1`, sur le modèle de `Kelix.Mod.Registrar.subscribe_register_event/2`. Aucune nouvelle dépendance côté elixip (pas de `Phoenix.PubSub`).

## Conséquences
- kelescope doit connaître et partager le cookie Erlang du nœud kelixip surveillé, au même titre que `kelictl`.
- kelescope doit tourner sur un réseau qui autorise la distribution Erlang (EPMD, plage de ports BEAM) vers ce nœud — idéalement un réseau de management dédié, ou la distribution Erlang en TLS (voir `kelixip_liveview.md`, « Security caveat »).
- Le cookie Erlang partagé donne à kelescope un accès RPC complet au nœud kelixip, bien au-delà de la lecture des scénarios. C'est un point de sécurité à traiter avant la Phase 3 (rôles et authentification) : à ce stade, tout accès à kelescope équivaut à un accès total au nœud kelixip.
- Surveiller plusieurs instances ou un cluster kelixip (Phase 2 et plus) demandera de gérer plusieurs connexions de nœud distinctes. Hors périmètre de la phase 1, qui ne couvre qu'une seule instance.
- L'API REST de contrôle reste disponible et documentée dans kelixip mais n'est pas utilisée par kelescope.

Détails d'implémentation : [docs/conception/phase1-monitoring/SPEC.md](../conception/phase1-monitoring/SPEC.md)
