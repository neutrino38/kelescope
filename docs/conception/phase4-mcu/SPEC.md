# Phase 4 — Écran MCU (`/mcu`)

## Objectif

Un nouvel écran, `/mcu`, pour gérer les conférences de la MCU (module `mcu`
d'elixip) : lister les conférences en cours, voir le détail d'une conférence,
ses participants et leurs statistiques média, en créer, en modifier
l'intégralité de ses propriétés (résolution/débit vidéo, codec vidéo
préféré, mode VAD, bascule automatique de mosaïque, fréquence audio, médias
répondus, logo), en détruire une, et démarrer/arrêter son enregistrement.
Les dispositions d'écran (layouts) sont représentées par des icônes imagées
plutôt que par leur seul nom.

Comme l'arrêt d'un scénario ou le désenregistrement d'un contact (phase 2),
créer ou détruire une conférence exige un nom d'administrateur, tracé côté
kelixip.

Une seule instance kelixip, comme dans les phases précédentes : pas de
multi-instance ni de cluster.

## Mécanisme côté elixip

Le module `mcu` (`apps/kelix_modules/lib/kelix/mod/mcu.ex`, dépôt elixip)
déclarait déjà tout le contrat nécessaire, atteint par le point d'entrée RPC
générique `Kelix.Control.module_command/3` (`apps/kelixip/lib/kelix/control.ex`)
que kelescope n'avait encore jamais mirroré :
`module_command("mcu", <commande>, <args string-keyed>)`, qui délègue à
`Kelix.Mod.Mcu.handle_control/2`.

Commandes utilisées ici : `conference.list`, `conference.show`,
`conference.create`, `conference.update` (fusion partielle — les champs omis
sont laissés tels quels), `conference.delete`, `recording.start`,
`recording.stop`, `participant.show` (une conférence dépliée réinterroge ce
dernier une fois par participant pour ses statistiques média).
`participant.update`/`participant.delete` (couper le micro ou expulser un
participant) et `slot.*` (épinglage de mosaïque) existent aussi côté elixip
mais ne sont pas exposés ici — hors périmètre, voir plus bas.

**Aucune poussée en direct** : `docs/design/DESIGN-MCU.md` (dépôt elixip, §11
et limitation L9) est explicite — les événements MCU (participant qui
rejoint/quitte, changement de layout, etc.) ne sont aujourd'hui lus que par le
logger, l'émetteur de métriques et le scénario propriétaire de la conférence,
jamais délivrés à un consommateur externe. Contrairement au suivi des
scénarios ou des compteurs de domaine, kelescope **sonde** (polling) la liste
des conférences toutes les 10 secondes, sur le modèle de
`Kelescope.Kelixip.StatusPoller` plutôt qu'un lien à abonnement. Le détail
d'une conférence (participants et leurs statistiques média compris) n'est pas
mis en cache non plus : il est réinterrogé à chaque dépli d'une ligne, avec un
bouton « Rafraîchir » manuel puisqu'aucun flux ne le met à jour tout seul.

### Trace admin sur `conference.create`/`conference.delete`

Aucune des deux commandes ne traçait un administrateur avant ce travail —
`@create_args` et l'allow-list de `conference.delete`
(`mcu.ex:129`, `mcu.ex:1198` au moment d'écrire ceci) n'avaient pas ce champ,
et `handle_control/2` ne prend que `(command, args)`. Patch apporté
(`apps/kelix_modules/lib/kelix/mod/mcu.ex`, dépôt elixip, édition locale) sur
le modèle exact de `unregister/4`/`shutdown_scenario/2`
(`docs/conception/phase2-monitoring-actions/SPEC.md`) : `admin` est extrait de
`args` (`Map.pop/2`), tracé par un `Logger.info` après exécution (même forme
que `unregister/4` : `"<action> ... by admin=#{admin || "unknown"}:
#{inspect(result)}"`), puis retiré des `args` avant le pipeline existant — les
allow-lists `@create_args`/`~w(uid force)` ne bougent pas, le contrat restant
inchangé pour tout autre appelant. `describe_control/0` documente le nouvel
argument optionnel pour que `kelictl mcu help` reste exact.

Ce patch elixip n'a pas encore été relu par l'équipe elixip au moment
d'écrire ceci — voir « Risques ».

## Modèle d'une conférence

`Conference.render/1` (`apps/kelix_modules/lib/kelix/mod/mcu/conference.ex`,
dépôt elixip) : `uid, name, domain, did, mcu, conf_id, vad, rate, medias,
dtmf, video (%{size, fps, bitrate, intra_period}), preferred_video_codec,
layout (%{comp, size, auto}), max_participants, destroy_when_empty,
persistent, created_at, stale, logo, recording (nom de fichier ou nil),
participants` — un compte sur `conference.list`, la liste rendue sur
`conference.show`. Un participant (`render_participant/1`) : `part_id, name,
from, state, medias, joined_at`.

`conference.create` ne renvoie que `%{uid, did, conf_id, mcu}` (+ `warning`
éventuel) — jamais la conférence complète : kelescope réinterroge la liste
après création plutôt que de faire confiance à cette réponse.

### Résolution et débit vidéo, codec préféré

`video.size` et `layout.size` partagent le même vocabulaire de résolutions
(`Kelix.Mod.Mcu.Vocabulary.@sizes`, dépôt elixip) et sont maintenus égaux côté
elixip (`align_sizes/4`, `mcu.ex` : « the mosaic canvas IS the encoded
picture ») — kelescope ne règle donc que `video.size`, jamais `layout.size`
directement, et laisse elixip aligner le second. Le formulaire ne propose
qu'un réglage de résolution parce que c'est le seul qui a un effet propre.

`preferred_video_codec` est une préférence déclarative (le premier codec cité
dans les réponses SDP de cette conférence), pas le résultat d'une
négociation : voir « Codecs négociés — non exposable » ci-dessous.

### Mode VAD et bascule automatique de mosaïque

`vad` (champ de premier niveau de la conférence, pas sous `video`) suit
`Kelix.Mod.Mcu.Vocabulary.@vads` : `0 none, 1 basic, 2 full`. Réglable en
création/modification comme les autres champs simples.

`layout.auto` (booléen) commande si la mosaïque change automatiquement de
disposition selon le nombre de participants vidéo
(`Kelix.Mod.Mcu.follow_auto_layout/1`, dépôt elixip) ; à `false`, le layout
choisi reste figé. Le formulaire l'envoie systématiquement (comme
`destroy_when_empty`) plutôt que de l'omettre quand la case n'est pas
cochée — sans quoi une conférence créée avec la case décochée redeviendrait
`auto: true` par défaut côté elixip au lieu de rester manuelle.

### Fréquence audio, médias répondus, logo

`rate` : `8000`, `16000`, `32000` ou `48000` (Hz) — les seules valeurs que
`Args.int/4` accepte côté elixip (`mcu.ex`), exposées en kHz dans le
formulaire.

`medias` : les types de média que la conférence répond (`audio`, `video`,
`text`, un ou plusieurs), trois cases à cocher indépendantes. **Aucune ne
transporte de liste de codecs** — depuis P8a, le média serveur arbitre seul
les codecs (voir « Codecs négociés — non exposable » ci-dessous) ; `medias`
ne fait que dire quels m= la conférence répond du tout. elixip refuse une
liste vide (« a conference that answers nothing ») : décocher les trois
cases ne vide donc jamais `medias`, kelescope omet le champ dans ce cas
plutôt que d'envoyer `[]` — la conférence garde ses médias déjà configurés.

`logo` : le nom nu d'une image déjà présente dans `image_dir` sur le média
serveur (dessinée dans chaque tuile vide de la mosaïque) — jamais un
téléversement depuis kelescope, juste le nom de fichier tel que
`Vocabulary.logo_help/0` le documente. **Ne peut pas être retiré d'une
conférence vivante** (L11, dépôt elixip) : le formulaire n'envoie donc
`logo` que si le champ n'est pas vide, jamais une chaîne vide pour
« l'effacer ».

### Statistiques média par participant — non exposable

`participant.show` (`kelictl mcu participant.show`) renvoie
`render_participant/1` fusionné aux statistiques RTP du média serveur
(`GetParticipantStatistics`, décodées par `Kelix.Mod.Mcu.decode_statistics/1`) :
un compte par média (`audio`/`video`/`text` selon ce que porte le
participant) de paquets et octets envoyés/reçus, paquets perdus en réception,
et si le média reçoit/émet effectivement. **Aucun codec n'y figure** : le
commentaire de `Conference.render/1` est explicite — *« the codecs themselves
are the media server's and not ours to report »*. Kelescope affiche donc les
compteurs RTP mais jamais le codec réellement négocié : cette information
n'existe dans aucune commande exposée par elixip aujourd'hui.

Une ligne dépliée fait un appel `participant.show` par participant affiché
(en plus du `conference.show` déjà fait) : coût accepté pour l'instant,
mêmes conditions de fraîcheur que le reste du détail (pas de mise en cache,
réinterrogé à chaque dépli/rafraîchissement).

## Layouts (mosaïques)

`Kelix.Mod.Mcu.Vocabulary.@mosaics` (dépôt elixip,
`apps/kelix_modules/lib/kelix/mod/mcu/vocabulary.ex`), ordre figé, id → nom :
`0 1x1, 1 2x2, 2 3x3, 3 3+4, 4 1+7, 5 1+5, 6 1+1, 7 pip1, 8 pip3, 9 4x4,
10 1+4, 11 2+8`. Douze layouts. Le layout se règle en création/modification
via `layout: %{"comp" => id, "auto" => bool}` (`Vocabulary.layout/2` accepte
l'id entier directement).

**Hypothèse assumée, non vérifiée** : aucun schéma visuel faisant autorité
n'a été trouvé pour `3+4`, `1+7`, `1+5`, `pip1`, `pip3`, `1+4`, `2+8` — le
média serveur les interprète lui-même, `DESIGN-MCU.md` ne les illustre pas.
Les douze icônes (`priv/static/images/layouts/0.svg` … `11.svg`, nommées par
id plutôt que par nom pour éviter les soucis d'échappement d'un `+` dans un
nom de fichier) dessinent une lecture conventionnelle du nom (ex. `1+7` = une
grande tuile + sept petites en bandeau, `pip1`/`pip3` = une grande tuile +
1/3 incrustations) plutôt qu'une disposition vérifiée auprès d'un opérateur
MCU ou d'un schéma du média serveur.

`Kelix.Mod.Mcu.Vocabulary.@sizes` (résolutions vidéo, id → nom) : `0 qcif,
1 cif, 2 vga, 3 pal, 4 hvga, 5 qvga, 6 hd720p, 7 wqvga, 14 xga, 15 wvga`. Dix
résolutions, exposées comme une liste déroulante (pas d'icône, contrairement
aux layouts).

`preferred_video_codec` : `H264`, `VP8` ou `AV1`
(`MediaServerMendoozeSdp.@video_codecs`, dépôt elixip,
`apps/elixip2/lib/framework/mendooze/MediaServerMendoozeSdp.ex`), ou aucune
préférence (`preferred_video_codec: nil` — une chaîne vide envoyée au
formulaire l'efface explicitement, comme `""`/`"none"` côté
`Vocabulary.video_codec/2`).

`vad` : `Kelix.Mod.Mcu.Vocabulary.@vads`, id → nom : `0 none, 1 basic,
2 full`.

## Composants livrés côté kelescope

### `Kelescope.Kelixip.Control`
`module_command/4`, wrapper générique RPC (`:rpc.call(node, Kelix.Control,
:module_command, [module, cmd, args])`), et huit fonctions sémantiques
au-dessus, même style que le reste du module : `list_conferences/2`,
`conference/2`, `participant/3` (uid, part_id — statistiques média),
`create_conference/3` (attrs, admin), `update_conference/3` (uid, attrs),
`delete_conference/4` (uid, admin, force \\ false), `start_recording/3`,
`stop_recording/2`.

### `Kelescope.Kelixip.ConferencesPoller`
Calqué sur `Kelescope.Kelixip.StatusPoller` : sonde `Control.list_conferences/2`
toutes les 10 s, diffuse `{:kelixip_conferences, conferences}` sur
`"kelixip:conferences"`. Câblé dans `Kelescope.Application` et
`config/runtime.exs` comme les autres liens (`node`/`cookie` communs).

### `KelescopeWeb.McuLive` (`/mcu`)
Liste des conférences (nom, domaine, mediaserver, nombre de participants,
icône de layout, badge « REC »). Une ligne entière (pas seulement le nom) est
cliquable pour se déplier : elle réinterroge `Control.conference/2`, puis
`Control.participant/3` pour chaque participant listé, et affiche les
propriétés complètes (dont résolution/débit vidéo, codec préféré, mode VAD,
bascule automatique de mosaïque, fréquence audio, médias répondus et logo),
les participants avec leurs statistiques média, et l'état d'enregistrement,
avec un bouton « Rafraîchir » manuel.

« Nouvelle conférence » ouvre un formulaire sur **deux colonnes** : à gauche
la conférence elle-même (domaine — liste déroulante des domaines servis, via
`Kelescope.Kelixip.DomainsLink.snapshot/0`, même source que l'écran
Domaines —, nom, participants max, mode VAD, fréquence audio, détruire quand
vide), à droite la vidéo et les médias (résolution, débit, codec préféré,
logo, médias répondus) ; le sélecteur de layout par icônes et sa bascule
automatique tiennent la pleine largeur en dessous. Une seule colonne
dépassait la hauteur de l'écran : le formulaire garde en plus un
`max-h-[85vh]` défilant, comme la popup mediaserver de l'écran Scénarios.

Sa soumission n'appelle pas encore kelixip — elle ouvre `admin_confirm_modal` (nom
d'administrateur), dont la confirmation appelle `Control.create_conference/3`
puis réinterroge la liste. « Détruire » par ligne suit le même schéma avec
`Control.delete_conference/4` (`force: false` — pas de case à cocher
« forcer » dans cet écran) ; `:not_empty` est affiché comme un message
d'erreur explicite plutôt que de faire planter la page.

« Modifier les propriétés » (dans le détail déplié) réutilise le même
formulaire, prérempli, mais l'applique directement via
`Control.update_conference/3` — **sans** `admin_confirm_modal`, seuls créer et
détruire l'exigent, sur demande explicite. Démarrer/arrêter l'enregistrement
(`Control.start_recording/3`/`stop_recording/2`) suit la même règle : pas de
confirmation admin.

### `dev_support/kelix_control_stub.ex`
`module_command/3` ajouté au double `Kelix.Control`, avec deux conférences
factices dédiées (`c-standup` sur `ms1`, layout `2x2` auto, résolution
`hd720p`, codec préféré `H264`, VAD `basic`, 32 kHz, médias `audio video
text`, sans logo, sans enregistrement ; `c-board` sur `ms2`, layout `1+1`
non auto, résolution `vga`, aucun codec préféré, VAD `basic`, 8 kHz, médias
`audio video`, logo `acme-logo.png`, en cours d'enregistrement) — isolées
des fixtures `example.com`/`test.local`/`throwaway.local` déjà utilisées
ailleurs, même logique que `throwaway.local` en phase 2. Reproduit les
mêmes atomes d'erreur que le vrai module (`:not_found`, `:not_empty`,
`:not_recording`, `:already_recording`) et la même trace `Logger.info` de
l'admin sur create/delete. `participant.show` y renvoie des statistiques
déterministes (dérivées du `part_id`), pas de véritables compteurs RTP.
`video.size`/`layout.size` y sont maintenus égaux (`align_layout_size/2`),
comme le fait elixip côté réel ; `medias: []` n'y est jamais accepté non
plus, même logique que le vrai module.

## Tests

- `Kelescope.Kelixip.ConferencesPollerTest`, calqué sur `StatusPollerTest`.
- `KelescopeWeb.McuLiveTest` : liste, dépli/détail/participants (dont leurs
  statistiques média), résolution/débit vidéo, codec préféré, mode VAD,
  bascule automatique de mosaïque, fréquence audio, médias répondus et logo
  affichés puis modifiables (y compris effacer la préférence de codec,
  désactiver la bascule automatique, et décocher tous les médias sans jamais
  les vider), domaine proposé en liste déroulante à la création, état
  « en cours d'enregistrement » à l'affichage, création puis destruction
  avec trace admin (`capture_log`, même piège de niveau de journalisation
  que les tests de phase 2), destruction d'une conférence non vide
  (`:not_empty` affiché sans crash), modification de propriétés (renommage +
  changement de layout), démarrage puis arrêt d'un enregistrement,
  rafraîchissement piloté par message direct au pid de la vue
  (`send(view.pid, {:kelixip_conferences, ...})`, même patron que documenté
  en phase 2 pour contourner le redémarrage du double `Kelix.Control` par
  d'autres fichiers de test).

  Les scénarios de création/modification/enregistrement créent leur propre
  conférence temporaire plutôt que de muter `c-standup`/`c-board` : l'ordre des
  tests dans un fichier n'est pas garanti (ExUnit mélange selon la seed), donc
  aucun test ne doit dépendre d'une mutation faite par un autre.

## Critères d'acceptation

- La liste des conférences se charge sans navigation et se rafraîchit toute
  seule au bout de 10 s au plus.
- Créer ou détruire une conférence exige un nom d'administrateur non vide ;
  kelixip trace ce nom dans ses journaux, au niveau `info`.
- Modifier les propriétés ou démarrer/arrêter un enregistrement n'exige pas
  de nom d'administrateur.
- Chaque layout affiche une icône distincte des onze autres.
- Une erreur RPC (conférence non trouvée, non vide, déjà enregistrée, pas en
  cours d'enregistrement) affiche un message, jamais un crash de page.
- Le domaine d'une nouvelle conférence se choisit dans une liste des domaines
  réellement servis, jamais saisi en texte libre.
- La résolution vidéo, le débit vidéo, le codec vidéo préféré, le mode VAD,
  la bascule automatique de mosaïque, la fréquence audio, les médias
  répondus et le logo d'une conférence sont visibles dans le détail et
  modifiables depuis le formulaire de propriétés.
- Décocher tous les médias ou vider le logo à la modification ne vide jamais
  ces champs côté elixip : kelescope omet le changement plutôt que d'envoyer
  une valeur que kelixip refuserait ou qu'il interdit d'effacer.
- Chaque participant affiché montre ses statistiques média (paquets/octets
  envoyés-reçus, perdus) quand le média serveur répond ; une conférence sans
  aucun participant n'en montre aucune.

## Hors périmètre

- Couper le micro ou expulser un participant (`participant.update`/`delete`
  existent côté elixip, non exposés ici).
- Codecs **négociés** par média (audio/vidéo/texte) : aucune commande
  elixip ne les expose (voir « Statistiques média par participant — non
  exposable » ci-dessus) — seule la préférence déclarative
  (`preferred_video_codec`) l'est.
- `slot.*` (épinglage manuel d'une mosaïque).
- Case « forcer » à la destruction (`force: true` sur `conference.delete`).
- Allocation de DID, sélection explicite du `mcu` (mediaserver) à la
  création.
- Téléversement d'une image de logo : le champ n'accepte qu'un nom de
  fichier déjà présent sur le média serveur (voir « Fréquence audio, médias
  répondus, logo » ci-dessus) — kelescope n'a pas de canal pour y déposer un
  fichier.
- Authentification et rôles (phase 3, README) : le nom d'administrateur saisi
  ici n'est pas vérifié, comme pour les autres actions admin-tracées.

## Risques

- Les icônes de layout dessinent une lecture conventionnelle du nom, non
  vérifiée auprès d'un schéma ou d'un opérateur MCU (voir « Layouts »
  ci-dessus) — à corriger si la disposition réelle diffère.
- Le patch elixip (trace admin sur `conference.create`/`delete`) n'est pas
  encore relu ni fusionné côté elixip au moment d'écrire ceci ; un rebase de
  cette branche pourrait en changer la forme, auquel cas cette page et le
  double de développement demandent un ajustement symétrique.
- L'absence de poussée en direct pour les conférences (contrairement aux
  scénarios/domaines/enregistrements) signifie qu'un opérateur peut voir une
  liste vieille de 10 s, et qu'un détail déplié ne se met à jour que sur un
  clic « Rafraîchir ». Accepté pour l'instant — DESIGN-MCU.md indique que la
  poussée d'événements MCU vers un consommateur externe n'est pas construite ;
  à revisiter si elixip l'ajoute un jour.
- Une conférence dépliée avec beaucoup de participants fait autant d'appels
  `participant.show` (donc de `GetParticipantStatistics` au média serveur)
  que de participants affichés, à chaque dépli et à chaque « Rafraîchir » —
  accepté pour l'instant faute d'un besoin observé de conférences à fort
  effectif ; à revisiter si cela pèse sur le média serveur en pratique.
- Le champ logo n'est pas validé côté kelescope (nom de fichier bien formé,
  fichier existant sur le média serveur) : une faute de frappe n'est signalée
  qu'au retour d'erreur d'elixip, affiché tel quel dans le formulaire.
