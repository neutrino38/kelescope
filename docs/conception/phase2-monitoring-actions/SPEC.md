# Phase 2 (suite) — Détail médiaserveur, état BDD, arrêt d'un scénario, désenregistrement d'un contact

## Objectif

L'écran des scénarios (`/`) gagne trois choses : un clic sur un médiaserveur du pool affiche son détail dans une popup, sans quitter l'écran ; une tuile « Connexion BDD » apparaît dans le bandeau d'état, seulement si le module `auth_db` est actif ; un bouton par ligne arrête (« graceful shutdown ») le scénario correspondant.

L'écran des domaines (`/domains`) gagne deux choses : la liste des enregistrements d'un domaine déplié se met à jour en direct (poussée par kelixip), sans qu'il faille replier puis redéplier ; un bouton par contact le désenregistre (retire un contact d'un AOR).

Arrêter un scénario et désenregistrer un contact sont deux actions destructrices sur un serveur en production. Chacune demande une confirmation dans une popup qui exige aussi un nom d'administrateur ; ce nom part avec la requête et kelixip le trace dans ses journaux (niveau `info`).

Une seule instance kelixip, comme en phase 1 : pas de multi-instance ni de cluster.

## Mécanisme côté elixip

Deux des trois besoins réutilisent des fonctions `Kelix.Control` qui existaient déjà pour `kelictl` ; kelescope leur ajoute un cinquième/deuxième argument optionnel, sans toucher aux arités existantes :

- `unregister/3` (`domaine`, `aor`, `contact`) existait déjà (`kelictl registration remove`). `unregister/4` ajoute `admin` : trace `Logger.info` (domaine, AOR, contact, admin, résultat) puis appelle `unregister/3` inchangée. Retourne `:ok` ou l'atome `:notfound` (jamais un tuple `{:error, :not_found}`) — c'est le contrat de `unregister/3`, `/4` ne le change pas.
- `shutdown_scenario/1` (`id`) existait déjà (`kelictl stop <id>`). `shutdown_scenario/2` ajoute `admin` de la même façon : trace puis délègue à `shutdown_scenario/1`. Retourne `:ok` ou `{:error, :not_found}` — c'est le contrat de `shutdown_scenario/1`, `/2` ne le change pas.

Une fonction est réellement nouvelle, sur le modèle de `subscribe_domain_counters/1` (phase 2 domaines) :

- `subscribe_registrations/2` (`pid`, `domaine`) — souscrit `pid` aux enregistrements d'un domaine (AOR et leurs contacts). Retourne l'état initial (`%{domain: nom_canonique, registrations: [...]}}`) puis pousse `{:kelix_registrations, domaine, {:upsert, enregistrement}}` et `{:kelix_registrations, domaine, {:remove, aor}}` à chaque changement — la même mécanique que `subscribe_domain_counters/1`, mais le détail complet d'un domaine plutôt qu'un compte, et un seul domaine à la fois plutôt que tous.

Les trois sont implémentées côté elixip (`apps/kelixip/lib/kelix/control.ex`, `apps/kelix_modules/lib/kelix/mod/registrar.ex`), décrites dans `docs/design/kelixip_liveview.md` (dépôt elixip, section « Registration detail push + admin-traced destructive actions »). Le double de développement (`dev_support/kelix_control_stub.ex`) les simule à l'identique, y compris la trace `Logger.info` et le `:notfound` bare atom d'`unregister`.

## Composants livrés côté kelescope

### `Kelescope.Kelixip.Control`
Trois fonctions RPC ajoutées, même forme que le reste du module : `subscribe_registrations/3`, `unregister/5`, `shutdown_scenario/3`. `registrations/2` (aller-retour simple, phase 2 domaines) est retirée : `DomainsLink.registrations/2` couvre le même besoin, avec la poussée en plus.

### `Kelescope.Kelixip.DomainsLink`
S'abonne à un domaine à la demande, pas à tous les domaines au démarrage : le premier appel à `registrations/2` pour un domaine donné déclenche l'abonnement RPC (`subscribe_registrations/3`) et met le domaine en cache ; les appels suivants pour le même domaine renvoient le cache sans nouvel aller-retour. Les poussées reçues (`{:kelix_registrations, domaine, {:upsert | :remove, ...}}`) mettent le cache à jour et sont republiées localement via `Phoenix.PubSub` sur `"kelixip:registrations:" <> domaine` — un sujet par domaine, pour qu'un onglet qui n'a pas déplié ce domaine ne reçoive pas ses mises à jour.

### `KelescopeWeb.DomainListLive` (`/domains`)
`toggle_registrations` s'abonne au sujet PubSub du domaine à l'ouverture et s'en désabonne à la fermeture (`Phoenix.PubSub.unsubscribe/2`) ; les poussées reçues mettent à jour `@registrations` par AOR (remplace ou ajoute sur `:upsert`, retire sur `:remove`), sans redemander l'état complet à kelixip.

Chaque contact affiché a un bouton « Désenregistrer » qui ouvre `admin_confirm_modal` (voir plus bas) ; la confirmation appelle `Control.unregister/5`, dont la valeur de retour n'est pas utilisée. La liste ne se met pas à jour depuis la réponse de cet appel : elle attend la poussée `{:kelix_registrations, domaine, {:remove, aor}}` que ce même appel déclenche côté kelixip, comme n'importe quel autre changement d'enregistrement.

### `KelescopeWeb.ScenarioMonitorLive` (`/`)
Un clic sur un médiaserveur du pool (badge devenu bouton) affiche son détail dans une popup : nom, module (adaptateur), adresse de contrôle, état activé/désactivé, santé, adresses réseau annoncées (`profiles`, un profil par famille d'adressage : `publicv4`/`publicv6`/`internalv4`/`internalv6`), et — quand la sonde a déjà lu `server_status` sur le médiaserveur — sa version, son uptime, les codecs audio/vidéo qu'il annonce (encodage et décodage séparément, ce sont deux listes distinctes), ses modes de sécurité et le nombre de conférences en cours. `profiles` et `server_status` valent `:unknown` tant qu'aucune sonde n'a abouti (juste après le démarrage de kelixip, ou pour un adaptateur qui ne les supporte pas) : la popup affiche alors « non disponibles » plutôt que de planter. Ces champs viennent tels quels de `Kelix.MediaPool.status/0`, déjà inclus dans `media_pool` par `status/1` — rien à ajouter côté elixip.

La tuile « Connexion BDD » n'apparaît que si `:auth_db` figure dans `@status.modules` ; elle lit `@status.module_status.auth_db.connected`. Ajouter une cinquième tuile sans ajouter de ligne : la grille passe de `sm:grid-cols-4` à `sm:grid-cols-5` quand la tuile est présente, plutôt que de laisser un cinquième élément déborder sur une nouvelle ligne. Comme cette tuile résume déjà `module_status.auth_db`, ce module est exclu de la liste générique « Modules » plus bas (`other_module_status/1`) pour ne pas l'afficher deux fois.

Un bouton « Arrêter » par ligne du tableau ouvre `admin_confirm_modal`, qui confirme avec `Control.shutdown_scenario/3`. La ligne disparaît via la poussée `{:kelix_monitor, {:remove, id}}` déjà en place depuis la phase 1, pas depuis la réponse de cet appel.

### `KelescopeWeb.CoreComponents.admin_confirm_modal/1`
Popup générique : titre, contenu libre, champ « Administrateur » obligatoire, valeurs cachées (`confirm_values`) resoumises avec ce nom sur `confirm_event`. Partagée entre l'arrêt d'un scénario et le désenregistrement d'un contact plutôt que dupliquée une fois par écran.

Confirmation par action plutôt qu'un champ « administrateur » persistant en haut de l'écran : un champ persistant, oublié après la première saisie, attribuerait une action à la mauvaise personne sur un poste partagé entre plusieurs administrateurs. Ce nom n'est pas authentifié — kelescope n'a pas encore d'authentification (phase 3, README) — c'est une saisie libre, tracée telle quelle : elle donne une trace, pas une garantie de sécurité.

### Double de développement (`dev_support/kelix_control_stub.ex`)
Un troisième domaine factice, `throwaway.local` (un AOR, `carol`), et une troisième ligne de scénario factice, `id: 3` (domaine `throwaway.local`) : dédiés à l'exercice des actions destructrices, pour ne jamais toucher aux fixtures `example.com`/`test.local`/`alice`/`bob` que les autres tests du dépôt utilisent déjà. `modules`/`module_status` du statut factice incluent `:auth_db` avec `connected: true`, pour que la tuile soit visible par défaut en développement (`mix phx.server`).

## Tests

- `KelescopeWeb.ScenarioMonitorLiveTest` : ouverture/fermeture de la popup médiaserveur, apparition conditionnelle de la tuile BDD selon `modules`, confirmation d'arrêt d'un scénario (trace de journal vérifiée par `capture_log`, avec le niveau de journalisation relevé le temps du test — `config/test.exs` le met à `:warning`, un `Logger.info` n'y survit pas sans ça), répercussion d'une suppression poussée.
- `KelescopeWeb.DomainListLiveTest` : confirmation de désenregistrement (même vérification de trace), répercussion d'une mise à jour ou d'une suppression d'enregistrement poussée.

Piège découvert en écrivant ces tests : `Kelix.Control` (le double) est un singleton partagé par toute la suite. `LinkTest` et `DomainsLinkTest` le redémarrent (`Supervisor.terminate_child` puis `restart_child`) pour leurs propres besoins d'isolation ; ce redémarrage réinitialise ses abonnés (`subs`, `registration_subs`), mais `Link` et `DomainsLink` (processus de longue durée, jamais redémarrés) continuent de se croire connectés. Une poussée envoyée après ce redémarrage, dans un autre fichier de test exécuté ensuite, ne les atteint plus — bien que rien ne l'indique côté LiveView (pas d'erreur, juste une mise à jour qui n'arrive jamais). D'où le choix, pour vérifier qu'une LiveView réagit bien à une poussée, d'envoyer le message directement au `pid` de la vue (`send(view.pid, msg)`, déjà le patron des tests de phase 1) plutôt que de passer par le vrai circuit kelixip → `Link`/`DomainsLink` → PubSub — réservé aux tests qui vérifient spécifiquement ce circuit (`LinkTest`, `DomainsLinkTest`).

## Critères d'acceptation

- Cliquer sur un médiaserveur du pool affiche son détail sans navigation ; fermer la popup (croix ou clic hors popup) revient à l'écran tel quel.
- La tuile « Connexion BDD » n'apparaît que si `auth_db` fait partie des modules actifs, jamais sinon.
- Arrêter un scénario ou désenregistrer un contact exige un nom d'administrateur non vide avant d'envoyer la requête ; kelixip trace ce nom dans ses journaux, au niveau `info`.
- La liste des enregistrements d'un domaine déplié se met à jour sans qu'il faille la replier puis la redéplier.
- Une erreur RPC n'affiche jamais un crash de page.

## Hors périmètre

- Authentification et rôles (phase 3, README) : le nom d'administrateur saisi ici n'est pas vérifié.
- Annulation d'un arrêt de scénario ou d'un désenregistrement déjà confirmé côté kelixip : ce sont des actions supposées immédiates et sans retour côté elixip.
- Historique des actions destructrices dans kelescope lui-même (kelescope ne journalise rien de son côté ; seul kelixip trace, via `admin`).

## Risques

- Le contrat est implémenté côté elixip (`apps/kelixip/lib/kelix/control.ex`, `apps/kelix_modules/lib/kelix/mod/registrar.ex`, tests associés) mais pas encore mergé/publié au moment d'écrire ceci : un rebase de la branche elixip avant fusion pourrait encore en changer la forme, auquel cas cette page et le double de développement demandent un ajustement symétrique.
- `DomainsLink` ne se désabonne jamais d'un domaine côté kelixip une fois abonné (pas de `unsubscribe_registrations` appelé côté kelescope, bien que la fonction existe côté elixip) : sur une instance kelixip avec beaucoup de domaines consultés au fil du temps, le nombre d'abonnements RPC ne fait que croître pour la durée de vie de `DomainsLink`. Accepté pour l'instant, à revisiter si le nombre de domaines consultés devient un souci.
- Le nom d'administrateur n'étant pas authentifié, rien n'empêche d'y saisir n'importe quoi : la trace est déclarative, pas une preuve. À revisiter une fois l'authentification (phase 3) en place.
