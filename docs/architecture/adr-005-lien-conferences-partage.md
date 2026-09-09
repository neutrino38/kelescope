# ADR-005 — Un lien partagé pour les conférences, et son comptage d'abonnés

## Contexte

Le module `mcu` de kelixip expose trois topics de poussée en direct pour les
conférences (dépôt elixip, `docs/design/mcu-live-push.md`) :

- la liste des conférences,
- une conférence et son roster,
- les statistiques média d'une conférence.

Le premier vaut pour toute la page. Les deux autres ne valent que pour une
ligne dépliée. Le troisième coûte cher : à chaque balayage, kelixip fait un
appel RPC par patte connectée, sur le canal de contrôle qu'il partage avec
l'établissement d'appel.

Il faut décider **qui détient la souscription** côté kelescope.

## Options

### A — Un processus relais par nœud, détenu par le LiveView

Chaque vue ouverte lance son propre relais. Le relais souscrit, étiquette
chaque message avec le nom du nœud, et le transmet à sa vue.

- Permet de surveiller plusieurs nœuds : la clé d'affichage devient
  `{nœud, uid}`, et l'étiquette vient de l'abonné, pas du message.
- Chaque vue est indépendante. Rien à compter, rien à partager.
- Mais **N vues ouvertes = N souscriptions**. Trois opérateurs regardant la
  même conférence font tourner trois balayages de statistiques au lieu d'un.
- Et cela ne ressemble à aucune des trois surfaces de poussée que kelescope
  consomme déjà.

### B — Un lien partagé, unique, qui rediffuse en PubSub

Un GenServer supervisé par l'application détient la souscription du nœud
configuré, garde le dernier état connu, et rediffuse en local via
`Phoenix.PubSub`. Les vues s'abonnent à un topic.

- C'est exactement ce que font `Kelescope.Kelixip.Link` (scénarios) et
  `Kelescope.Kelixip.DomainsLink` (compteurs de domaine et enregistrements).
- Une seule souscription par topic, quel que soit le nombre de vues ouvertes.
  Un seul balayage de statistiques.
- Mais le désabonnement devient un problème : quand une vue replie une ligne,
  le lien ne doit couper la souscription **que si plus personne ne la regarde**.

## Décision

**Option B**, avec un comptage d'abonnés.

Deux raisons, dans cet ordre.

**kelescope ne surveille qu'un seul nœud.** `KELIXIP_NODE` porte une valeur
unique, reprise à l'identique par chaque lien dans `config/runtime.exs`. Le
multi-instance et le cluster sont hors périmètre depuis la phase 1. L'argument
principal de l'option A — attribuer un message à son nœud émetteur — ne
répond donc à aucun besoin d'aujourd'hui.

**Le coût du balayage se paie côté serveur.** Multiplier les souscriptions
statistiques par le nombre d'onglets ouverts met des appels RPC devant
l'établissement d'appel. Le contrat le dit lui-même : une souscription
statistique laissée ouverte est un bug de performance, pas un détail
d'affichage. Le partage n'est pas une élégance, c'est ce qui borne la charge.

## Conséquences

`Kelescope.Kelixip.ConferencesLink` tient une table de **prises** (`holds`) :
pour chaque `{genre, uid}`, l'ensemble des processus qui la réclament.

- `watch_conference/2` et `watch_stats/2` ajoutent le processus appelant.
  La première prise déclenche la souscription RPC.
- `unwatch_conference/2` et `unwatch_stats/2` la retirent. La dernière prise
  retirée déclenche le désabonnement RPC.
- Le lien fait un `Process.monitor` sur chaque abonné. Une vue qui meurt sans
  se désabonner libère ses prises toute seule.

C'est un mécanisme que `DomainsLink` n'a pas : il souscrit aux enregistrements
d'un domaine à la demande et ne s'en désabonne jamais. C'était tolérable pour
des enregistrements, qui ne coûtent rien à pousser. Ça ne l'est pas ici.

Deuxième conséquence : le lien détient aussi le `Process.monitor` sur le
**propriétaire** de la souscription, que chaque `subscribe_*` renvoie. Si le
module `mcu` est rechargé, ses listes d'abonnés disparaissent sans prévenir.
Le lien le voit, se réabonne, et recharge les snapshots — la poussée a pu
manquer des changements pendant le trou.

Si kelescope doit un jour surveiller plusieurs nœuds, cette décision est à
rouvrir : il faudra un lien par nœud, et l'étiquetage `{nœud, uid}` que
l'option A décrit.
