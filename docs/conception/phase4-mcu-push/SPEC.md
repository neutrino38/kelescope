# Phase 4 — Conférences en direct (suppression du bouton « Rafraîchir »)

## Objectif

L'écran `/mcu` se met à jour tout seul. Plus de sondage toutes les 10 secondes
pour la liste. Plus de bouton « Rafraîchir » sur une ligne dépliée.

Cinq choses arrivent en poussée :

1. une conférence est créée,
2. une conférence est modifiée,
3. une conférence est détruite,
4. un participant arrive ou part,
5. les statistiques média de chaque patte, toutes les 15 secondes, **seulement
   tant qu'un panneau est déplié**.

## Le contrat côté elixip

Il est spécifié dans le dépôt elixip, `docs/design/mcu-live-push.md` (branche
`release/1.5.4`). Il étend aux conférences la doctrine de poussée que kelescope
consomme déjà pour les scénarios, les compteurs de domaine et les
enregistrements.

**Le module est écrit, la façade ne l'est pas encore.** `Kelix.Mod.Mcu` porte
les six fonctions, `Kelix.Mod.Mcu.Push` la table d'abonnés et
`Kelix.Mod.Mcu.Stats` le balayage. Mais `Kelix.Control` n'expose aucune des six.
kelescope appelle la façade, comme pour les trois autres surfaces, et reçoit
donc toujours un `:undef`. Voir « Questions à remonter ».

### Les six fonctions

```elixir
subscribe_conferences(pid)          :: {:ok, %{owner: pid | nil, conferences: [map]}}
unsubscribe_conferences(pid)        :: :ok

subscribe_conference(pid, uid)      :: {:ok, %{owner: pid, conference: map, participants: [map]}}
                                     | {:error, :not_found}
unsubscribe_conference(pid, uid)    :: :ok

subscribe_conference_stats(pid, uid) :: {:ok, %{owner: pid, interval_ms: pos_integer}}
                                      | {:error, :not_found | :disabled}
unsubscribe_conference_stats(pid, uid) :: :ok
```

### Les messages reçus

```elixir
{:kelix_conferences, {:upsert, conf_row}}
{:kelix_conferences, {:remove, uid}}

{:kelix_conference, uid, {:snapshot, %{conference: conf_row, participants: [part_row]}}}
{:kelix_conference, uid, :destroyed}

{:kelix_conference_stats, uid, sample}
```

`conf_row` est ce que renvoient déjà `conference.list` et `conference.show`.
`part_row` est ce que renvoie `participant.list`. Ce sont les mêmes fonctions de
rendu, pas des copies : la lecture initiale et la poussée ne peuvent pas se
contredire.

### Ce que le contrat garantit

- **Ni trou ni doublon** sur la liste et sur une conférence : l'enregistrement
  de l'abonné et la lecture de son snapshot tiennent dans le même message du
  GenServer, et tout ce qui publie une ligne passe par ce processus. Rien ne
  peut se glisser entre les deux. kelescope reste malgré tout idempotent : la
  garantie ne couvre pas le topic statistiques, et le rechargement après un
  `:DOWN` rejoue forcément.
- **Chaque message porte toute la vérité** de ce qu'il nomme : ligne complète,
  roster complet, échantillon complet. Aucun diff, aucun numéro de séquence.
  Appliquer deux fois le même message ne change rien.
- Un `{:remove, uid}` ou un `:destroyed` peut nommer une conférence jamais vue.
  On l'ignore.
- **Le roster est ordonné par admission, du plus ancien au plus récent.**
  kelescope le remplace tel quel : un tableau dont les lignes bougent seules
  est illisible.
- **Une conférence détruite garde ses souscriptions.** C'est à l'abonné, qui
  vient de recevoir `:destroyed`, de se désabonner. kelescope le fait en
  refermant le panneau.
- L'ordre est préservé **par topic**. Aucun ordre **entre** topics : un
  `:kelix_conference` peut arriver avant le `:kelix_conferences` qui lui
  correspond.

## Architecture retenue

`Kelescope.Kelixip.ConferencesLink` remplace `Kelescope.Kelixip.ConferencesPoller`.

C'est un GenServer unique, supervisé par `Kelescope.Mcu.Application`, calqué sur
`Kelescope.Kelixip.DomainsLink`. Il détient les souscriptions du nœud configuré
et rediffuse en local via `Phoenix.PubSub`. Les vues ne parlent jamais au nœud
pour ces trois flux : elles s'abonnent à un topic.

| Topic | Ce qu'il porte |
|---|---|
| `"kelixip:conferences"` | la liste : `{:snapshot, rows}`, `{:upsert, row}`, `{:remove, uid}` |
| `"kelixip:conference:<uid>"` | une conférence et tout son roster |
| `"kelixip:conference_stats:<uid>"` | les échantillons de statistiques |
| `"kelixip:conferences_link"` | `{:kelixip_conferences_link, :push \| :poll}` |

Le choix d'un lien partagé, plutôt que d'un relais par vue, est décidé dans
[ADR-005](../../architecture/adr-005-lien-conferences-partage.md). Il tient à
deux faits : kelescope ne surveille qu'un nœud, et le balayage de statistiques
coûte cher côté serveur.

### Les prises (comptage d'abonnés)

Le lien étant partagé, il ne peut pas se désabonner dès qu'une vue replie une
ligne : une autre vue peut la regarder encore.

Il tient donc une table `holds` : pour chaque `{genre, uid}`, l'ensemble des
processus qui la réclament.

- `watch_conference/2` et `watch_stats/2` ajoutent le processus appelant. La
  **première** prise déclenche la souscription RPC.
- `unwatch_conference/2` et `unwatch_stats/2` la retirent. La **dernière** prise
  retirée déclenche le désabonnement RPC.
- Le lien fait un `Process.monitor` sur chaque abonné : une vue qui meurt sans
  se désabonner libère ses prises toute seule.

### Vivacité du propriétaire

Chaque `subscribe_*` renvoie le pid qui détient la liste d'abonnés. Si le module
`mcu` est rechargé, cette liste disparaît et **rien ne prévient l'abonné** :
c'est exactement le bug qui ramènerait le bouton de rafraîchissement.

Le lien fait donc un `Process.monitor` sur ce propriétaire. Sur `:DOWN`, il se
reconnecte : il re-souscrit la liste, re-souscrit **chaque prise encore
détenue**, et rediffuse leurs snapshots. La poussée ne peut pas dire ce qui a
changé pendant le trou.

La reconnexion passe par un délai (`retry_after`, 5 s). Ce n'est pas de la
politesse : voir « Questions à remonter ».

### Sonde de capacité et repli

À la connexion, le lien appelle `subscribe_conferences/1`. Un nœud qui ne sert
pas le contrat répond `{:badrpc, {:EXIT, {:undef, _}}}`. Le lien bascule alors
en mode `:poll` : il lit `conference.list` toutes les 10 secondes et publie un
`{:snapshot, rows}`, ce que faisait le poller précédent.

**Le cycle de sondage est aussi le cycle de re-tentative.** Chaque tick réessaie
d'abord la souscription. Un kelixip mis à jour sur place reprend donc la poussée
sans redémarrage de kelescope. Le coût est un `:undef` par tick sur un vieux
nœud, ce qui ne réveille aucun balayage.

En mode `:poll`, `watch_conference/2` et `watch_stats/2` répondent
`{:error, :unavailable}`. La vue retombe sur son comportement d'avant :
`conference.show` + un `participant.show` par participant, et le bouton
« Rafraîchir » réapparaît. C'est le seul endroit où ce bouton existe encore.

## Les trois panneaux

### Liste

Chargée par le snapshot de `subscribe_conferences/1`, pas par un
`conference.list` séparé — un appel séparé rouvrirait la course que la
souscription ferme.

Ensuite `:upsert` et `:remove`. Le nombre de participants est porté par la
ligne : un arrivant met la liste à jour sans que la ligne soit dépliée.

Un `:upsert` d'un domaine hors de la portée du compte connecté est ignoré avant
l'assign, comme le faisait déjà le filtrage du snapshot.

### Conférence dépliée

`subscribe_conference/2`, puis **remplacement intégral** du roster à chaque
`:snapshot`. Aucun delta n'est fabriqué côté client : le contrat pousse le
roster entier parce qu'une patte en sonnerie n'a pas encore d'identifiant
stable (`part_id: nil`), donc rien sur quoi appuyer un `{:remove, clé}`.

Sur `:destroyed`, le panneau se referme. La ligne, elle, part par le `:remove`
de la liste.

Un `:kelix_conference` qui ne nomme pas la ligne dépliée est ignoré : après un
désabonnement, ce qui restait dans la boîte aux lettres arrive quand même.

### Statistiques

`subscribe_conference_stats/2`, sur le même dépliement, et libéré au même
repliement.

La réponse ne porte **pas** de premier échantillon : elle donne l'intervalle.
Le premier échantillon arrive en poussée, tout de suite (le nœud balaie une
souscription neuve sur place). Le panneau montre donc une colonne vide pendant
un instant, jamais un chiffre inventé.

kelescope ne recalcule **aucun débit** et ne garde aucun échantillon précédent :
`recv_kbps`, `send_kbps` et `lost_recv_delta` sont calculés par le nœud. C'est
une décision du contrat, pas une commodité — une UI qui les calculerait
elle-même n'afficherait rien après un rechargement de page.

Quatre situations sont rendues visibles, jamais masquées :

| Situation | Ce que l'écran montre |
|---|---|
| `stats_error` non nul sur une patte | « pas de réponse », en avertissement, les autres pattes restent affichées |
| `since_ms` supérieur au double de l'intervalle | « chiffres vieillissants (N s) » : MCU lent, pas file d'attente |
| `{:error, :disabled}` à la souscription | « Statistiques média désactivées sur ce nœud », pas de panneau vide |
| `part_id: nil` | « en sonnerie » : cette patte n'a pas de statistiques possibles, ce n'est pas une panne |

Distinguer « pas de réponse » de « pas de média » est le point : un opérateur
qui lit des zéros doit savoir lequel des deux il regarde.

L'heure de l'échantillon (`at`) est affichée sous le tableau.

## Ce que kelescope suppose, faute d'implémentation côté elixip

Le double `Kelix.Control` (`apps/kelescope_core/dev_support/kelix_control_stub.ex`)
implémente les six fonctions et la poussée, pour que l'écran soit construit et
testé avant que le contrat n'existe.

- Il compare la table des conférences avant et après chaque commande et pousse
  ce qui a changé. C'est la moitié observable de ce que fera le
  `Event.emit/3` d'elixip, et cela ne peut pas dériver de la liste des
  commandes.
- `set_participants/2` remplace un roster, faute de commande qui produise un
  événement de participant.
- `push_stats/2` injecte un échantillon ; le balayage automatique suit le tick
  de 3 secondes du double.
- `set_push_capability/1` éteint les six fonctions. Elles sortent alors en
  `exit({:undef, …})` depuis le processus appelant, ce qui fait rendre à
  `:rpc.call/4` exactement le `{:badrpc, {:EXIT, {:undef, _}}}` d'une fonction
  réellement absente. Un double qui renverrait un `{:error, _}` n'exercerait
  jamais la branche qui compte.
- `set_stats_interval(0)` reproduit `{:error, :disabled}`.

## Tests

`apps/kelescope_mcu/test/conferences_link_test.exs` — le lien seul, avec son
propre double et ses propres topics, sur le modèle de `LinkTest` :

- souscription au démarrage, snapshot publié, mode `:push` ;
- `:upsert` et `:remove` rediffusés, et reflétés dans son propre snapshot ;
- le même `:upsert` appliqué deux fois ne laisse qu'une ligne ;
- un `:remove` d'une conférence inconnue ne change rien et ne plante pas ;
- un nœud sans le contrat bascule en sondage, et `watch_*` y répond
  `{:error, :unavailable}` ;
- **un nœud mis à jour sur place** reprend la poussée au tick suivant, sans
  redémarrage de kelescope ;
- une prise survit au départ d'un abonné sur deux, et tombe avec le dernier ;
- un abonné qui meurt sans se désabonner libère ses prises ;
- `{:error, :disabled}` et `{:error, :not_found}` remontés tels quels ;
- une souscription statistiques pousse son premier échantillon sans qu'on
  redemande ;
- **le propriétaire qui meurt** : re-souscription de la liste et de chaque
  prise, snapshots rechargés.

`apps/kelescope_mcu/test/kelescope_web/mcu_live_test.exs` — l'écran :

- une conférence créée ailleurs apparaît sans aucune interaction, et disparaît
  de même ;
- un changement de roster remplace le roster affiché ;
- une conférence détruite referme son panneau ;
- **replier une ligne libère les deux souscriptions** (le test lit la table
  `holds` du lien : il échoue si l'on retire les appels `unwatch_*`) ;
- une patte en sonnerie, une patte illisible, un échantillon vieillissant ;
- un message dupliqué ne change rien ;
- un `:remove` inconnu est ignoré ;
- un `:kelix_conference` reçu sans son `:kelix_conferences` n'est pas perdu ;
- pas de bouton « Rafraîchir » tant que le nœud pousse.

### Deux pièges de test, documentés parce qu'ils se répètent

**La synchronisation.** L'effet d'une action ne revient plus avec le clic : il
passe par kelixip, puis le lien, puis la vue. Les tests appellent `settle/1`,
qui vide la boîte aux lettres du double puis celle du lien. La diffusion est
alors déjà partie, donc placée devant le rendu dans la boîte de la vue. C'est
une attente sur un fait, pas un `sleep` sur une estimation.

**Le mode.** Tout fichier de test qui s'empare du double `Kelix.Control` tue le
pid que le lien global surveille comme propriétaire. Le lien se reconnecte sur
son propre minuteur. `mcu_live_test.exs` attend donc le mode `:push` dans son
`setup` : sinon il testerait le repli sans le savoir. `config/test.exs`
raccourcit `retry_after` et `poll_interval` à 100 ms pour que cette attente
reste courte.

## Critères d'acceptation

- Une conférence créée, modifiée ou détruite ailleurs se voit sur l'écran sans
  aucune interaction.
- Un participant qui arrive ou part met à jour le compte de la ligne, dépliée
  ou non, et le roster si elle est dépliée.
- Une ligne dépliée n'a pas de bouton « Rafraîchir ».
- Replier une ligne coupe sa souscription statistiques côté nœud.
- Deux vues sur la même conférence ne font tourner qu'un seul balayage.
- Un nœud sans le contrat affiche la liste et le détail comme avant, bouton
  « Rafraîchir » compris, sans erreur ni panneau vide.
- Un rechargement du module `mcu` ne laisse pas l'écran figé sur des chiffres
  morts.

## Questions à remonter à elixip

**Bloquant : la façade `Kelix.Control` n'existe pas.** Le document décrit une
« `Kelix.Control` surface » de six fonctions, `Kelix.Mod.Mcu` documente être
« reached through `Kelix.Control.subscribe_conferences/1` », et
`apps/kelix_modules/test/mcu_push_test.exs` les appelle. Mais
`apps/kelixip/lib/kelix/control.ex` ne les définit pas : sa dernière fonction
publique reste `module_command/3`.

Conséquence directe : kelescope reçoit toujours `{:badrpc, {:EXIT, {:undef,
_}}}` et reste en repli. Le test elixip cité ne peut pas passer non plus.

Il manque les six délégations à travers `Kelix.ModuleRegistry.facade`, avec les
défauts que le document décrit lui-même : `{:ok, %{owner: nil, conferences: []}}`
pour la liste, `{:error, :not_found}` pour les deux autres.

kelescope n'appellera pas `Kelix.Mod.Mcu` directement pour contourner : la
façade est la frontière, comme pour les trois autres surfaces.

**Le filtrage par domaine.** Le topic liste pousse toutes les conférences du
nœud. kelescope filtre côté client, sur le champ `domain` de la ligne, comme il
le faisait déjà. Pour un compte à portée limitée, la ligne transite quand même
par le processus de la vue avant d'être écartée. Le contrat le note comme
question ouverte ; kelescope n'en a pas besoin aujourd'hui.

**`conference.update` ne trace pas d'administrateur.** `conference.create` et
`conference.delete` le font depuis 2026-09-08. `conference.update` non, alors
qu'elle est tout aussi destructrice depuis le siège d'un opérateur. Le contrat
le liste aussi comme question ouverte.

## Risques

- Tant que la façade manque, kelescope tourne en mode `:poll` contre un vrai
  nœud, et tout le chemin de poussée n'est exercé que par le double. Les formes
  de `conf_row`, `part_row` et `sample` sont celles du document ; un écart à
  l'implémentation se verra au premier essai contre un vrai nœud.
- `mark_stale/1` émet désormais `conference.updated` avec `stale: true` quand un
  média serveur tombe (piège 2 du contrat, implémenté côté elixip). kelescope
  affiche `stale` dans le détail déplié, mais **pas** dans la liste : une
  conférence morte y reste affichée comme saine tant qu'on ne la déplie pas.
  À corriger.
- Le lien garde en mémoire le dernier roster et le dernier échantillon de chaque
  conférence surveillée. Borné par le nombre de lignes dépliées, donc par le
  nombre d'onglets ouverts, mais rien ne le plafonne explicitement.
