# Découpage du paquet RPM

## Objectif

Livrer une correction de kelescope sans expédier 7,6 Mo, et sans couper le
service.

Le paquet est découpé en un socle runtime et quatre applications OTP installées
hors de la release. Un chargeur les monte au démarrage. Une mise à jour d'une
partie recharge ses modules dans le nœud en marche.

Décision et options écartées :
[ADR-002](../../architecture/adr-002-decoupage-paquets-rpm.md).

## Contraintes mesurées

Relevées sur `kelescope-0.1.1-1.el9.x86_64.rpm`.

| Contenu | Taille |
|---|---|
| Release installée | 19 Mo (RPM : 7,6 Mo) |
| ERTS et les 34 dépendances | ~18,4 Mo |
| Application `kelescope` | 548 Ko (`ebin` 121 Ko, `priv` 427 Ko) |

`releases/0.1.1/start.script` précharge la liste exacte des modules de
`kelescope` par une directive `primLoad`, et le nœud tourne en mode `embedded`.
Une application citée dans le boot script n'est donc pas remplaçable seule.
L'option `:none` de `mix release` ne lève pas cette contrainte : `iex` est
déclaré `none` dans `kelescope.rel` et reste préchargé.

## Architecture cible

### Arborescence installée

```
/opt/kelescope/
├── erts-14.2.5/                        ┐
├── lib/<dépendances>/                  │
├── releases/<abi>/                     ├─ kelescope-runtime
├── bin/kelescope                       │
├── bin/kelescope-reload-plugin         ┘
└── plugins/
    ├── kelescope_core-1.0.0/{ebin,priv}     ─ kelescope-core
    ├── kelescope_monitor-1.0.0/ebin         ─ kelescope-monitor
    ├── kelescope_domaines-1.0.0/ebin        ─ kelescope-domaines
    └── kelescope_mcu-1.0.0/ebin             ─ kelescope-mcu
```

`bin/kelescope`, `/opt/kelescope`, l'unité systemd et
`/etc/kelescope/kelescope.env` ne changent pas. L'exploitant ne voit aucune
différence de procédure.

### Le chargeur `kelescope_boot`

`kelescope_boot` est l'application principale de la release. La release garde le
nom `kelescope`, donc `bin/kelescope` reste inchangé.

`kelescope_boot` ne contient que le chargeur. Son `mix.exs` déclare en revanche
**toutes les dépendances hex** du projet : c'est lui qui décide de la charge
utile embarquée dans la release.

Le répertoire des plugins vaut `<RELEASE_ROOT>/plugins`, surchargeable par
`KELESCOPE_PLUGINS_DIR` pour le développement et les tests.

Séquence de chargement, dans cet ordre :

1. lister `plugins/*/ebin`, et `:code.add_pathz/1` sur chacun ;
2. `Application.load/1` sur chaque application trouvée ;
3. pour chaque application, charger explicitement les modules listés dans la
   clé `modules` de son fichier `.app`, par `:code.load_file/1` ;
4. `Application.ensure_all_started/1` sur chaque application chargée.

L'étape 3 n'est pas une optimisation. Sans elle, l'étape 4 échoue sur un `undef`
de `<Application>.start/2` : en mode `embedded`, rien ne se charge à la demande,
et les modules d'un plugin ne figurent dans aucun `primLoad`. Ce mode est
conservé volontairement. Un module manquant se signale au démarrage, pas six
heures plus tard.

L'étape 4 laisse OTP résoudre l'ordre à partir des dépendances déclarées.
`kelescope_core` démarre donc avant les autres, sans que le chargeur ait à
connaître cet ordre.

**La séquence ne s'exécute pas depuis `start/2`.** Appeler
`Application.ensure_all_started/1` depuis la fonction `start/2` d'une autre
application bloque sans fin : le contrôleur d'applications d'OTP est occupé à
démarrer l'appelant. `kelescope_boot` supervise donc un processus
`Kelescope.Boot.Starter`, dont `init/1` retourne `{:ok, state, {:continue,
:load}}`. `start/2` rend la main, le contrôleur se libère, puis
`handle_continue/2` exécute la séquence.

Un échec à l'une des quatre étapes arrête le nœud avec un message nommant
l'application et la cause. Pas de démarrage partiel silencieux.

### Gel des versions OTP

Les quatre applications portent la version OTP `1.0.0`, figée. C'est un numéro
d'ABI : le contrat interne entre le socle et les parties. Il ne bouge qu'à une
rupture de ce contrat, et ce mouvement est alors une décision explicite.

La version produit vit uniquement dans le champ `Version` du RPM.

Sans ce gel, le nom des répertoires change à chaque livraison, et le découpage
s'effondre.

Chaque application expose sa version produit dans son environnement applicatif,
sous la clé `:build`. Le `mix.exs` la lit dans la variable
`KELESCOPE_BUILD_VERSION` au moment de la compilation. Le `%build` du spec
exporte cette variable depuis `%{version}-%{release}`.

### Les quatre applications

| Application | Contenu |
|---|---|
| `kelescope_core` | `Endpoint`, `Router`, `Layouts`, `CoreComponents`, `Gettext`, `Telemetry`, `ErrorHTML`, `ErrorJSON`, `LocaleController`, `LocaleHook`, `Kelixip.Link`, `Kelixip.Control`, et tout `priv` (assets, gettext) |
| `kelescope_monitor` | `ScenarioMonitorLive`, `Kelixip.StatusPoller` |
| `kelescope_domaines` | `DomainListLive`, `Kelixip.DomainsLink` |
| `kelescope_mcu` | `McuLive`, `Kelixip.ConferencesPoller` |

Chaque partie porte sa propre supervision. `StatusPoller`, `DomainsLink` et
`ConferencesPoller` quittent `Kelescope.Application` pour le superviseur de leur
partie. C'est ce qui permet d'arrêter et de redémarrer une partie sans toucher
au reste.

Le routeur reste dans le socle. `live "/mcu", McuLive` ne stocke qu'un atome,
résolu à l'exécution : le socle route vers un module livré par un autre RPM sans
en dépendre à la compilation.

Le projet devient un umbrella : `apps/kelescope_boot`, `apps/kelescope_core`,
`apps/kelescope_monitor`, `apps/kelescope_domaines`, `apps/kelescope_mcu`.

## Découpage des sous-paquets RPM

Un seul fichier spec, `rpm/kelescope.spec`.

| Paquet | Contenu | Taille estimée |
|---|---|---|
| `kelescope` | méta-paquet, aucun fichier | — |
| `kelescope-runtime` | ERTS, dépendances, `releases/`, `bin/`, unité systemd, `kelescope.env` | ~7,5 Mo |
| `kelescope-core` | `plugins/kelescope_core-1.0.0` | ~250 Ko |
| `kelescope-monitor` | `plugins/kelescope_monitor-1.0.0` | ~20 Ko |
| `kelescope-domaines` | `plugins/kelescope_domaines-1.0.0` | ~25 Ko |
| `kelescope-mcu` | `plugins/kelescope_mcu-1.0.0` | ~35 Ko |

Règles de dépendances :

- les quatre parties portent `Requires: kelescope-runtime >= <version minimale>` ;
- les trois fonctionnalités portent `Requires: kelescope-core >= <version minimale>` ;
- le méta-paquet `kelescope` porte un `Requires: … >= <version minimale>` sur
  chacun des cinq autres.

Toujours `>=`, jamais une égalité stricte. Une égalité stricte empêcherait la
mise à jour d'une seule partie, c'est-à-dire tout l'intérêt du découpage.

La version minimale se relève à la main, dans le spec, quand une partie commence
à employer une nouveauté du socle. C'est une décision de développement, pas un
calcul automatique.

Les scriptlets existants — création du compte `kelixip`, macros systemd, invite
interactive de première installation — vont dans `kelescope-runtime`.

## Construction

`%build` compile l'umbrella, construit les assets, puis produit la release.

`mix release` n'embarque que `kelescope_boot` et les dépendances hex. Les quatre
parties ne figurent pas dans le `.rel`, parce qu'elles ne sont pas dépendances de
`kelescope_boot`.

`%install` copie ensuite, pour chaque partie, **uniquement `ebin/` et `priv/`**
depuis `_build/prod/lib/<application>/` vers
`%{buildroot}/opt/kelescope/plugins/<application>-1.0.0/`. Le répertoire
`consolidated/` produit par la compilation ne doit pas être copié : les
protocoles consolidés de la release vivent dans `releases/<abi>/consolidated`, et
un second exemplaire à côté des plugins n'est qu'un piège.

Deux contrôles au build, qui décident si le paquet `kelescope-core` doit être
livré avec les autres :

- le condensat de `priv/static/assets/app.css` et de `app.js` ;
- l'ensemble des `msgid` compilés dans le backend `KelescopeWeb.Gettext`.

Si l'un des deux change, `kelescope-core` doit être livré. Le build l'affiche.
Sans ce contrôle, une partie livrée seule référence des classes CSS absentes du
socle installé, et l'affichage est faux sans aucune erreur.

## Rechargement à chaud

`bin/kelescope-reload-plugin <application>`, livré par `kelescope-runtime` :

1. sort en succès si le service n'est pas actif — rien à recharger ;
2. source `/etc/kelescope/kelescope.env` — un script lancé par rpm n'hérite pas
   de l'environnement systemd, il lui manquerait `RELEASE_NODE`,
   `RELEASE_COOKIE` et `RELEASE_DISTRIBUTION` ;
3. appelle `bin/kelescope rpc` sur le chargeur ;
4. retombe sur `systemctl try-restart kelescope` si l'appel échoue, quelle qu'en
   soit la cause.

Jamais de silence. Un nœud qui tourne avec du code périmé est pire qu'un
redémarrage.

`Kelescope.Boot.Loader.reload/1`, exécuté dans le nœud :

1. relève la liste des modules courants de l'application ;
2. `Application.stop/1` ;
3. `Application.unload/1` puis `Application.load/1`, pour relire le `.app` sur
   disque — la liste des modules et les valeurs par défaut ont pu changer ;
4. `:code.purge/1` puis `:code.delete/1` sur les modules disparus de la nouvelle
   liste ;
5. `:code.purge/1` puis `:code.load_file/1` sur chaque module de la nouvelle
   liste ;
6. `Application.ensure_all_started/1`.

Le `%posttrans` de chaque paquet de partie appelle ce script. `%posttrans`
s'exécute une fois en fin de transaction : la mise à jour simultanée de
plusieurs parties ne déclenche pas plusieurs rechargements de la même partie.

Le `%postun` d'une partie, en cas de désinstallation (`$1 -eq 0`), appelle
`systemctl try-restart kelescope`. Le nœud repart sans la partie retirée.

Limite assumée : les processus LiveView tournent sous la supervision de
`kelescope_core`, pas sous celle de leur partie. `:code.purge/1` sur un module
de page tue donc les onglets ouverts sur cette page, et le client remonte. Le
comportement observé est celui d'un redémarrage, pour un seul onglet.

## Version réellement chargée

Le numéro de version du RPM ne décrit plus ce qui tourne. Une machine peut
porter un socle `0.2.0` et une partie `0.3.1`.

`Kelescope.Boot.Loader.versions/0` retourne, pour chaque application chargée,
son nom, sa version d'ABI et sa version produit (clé `:build`).

`bin/kelescope rpc "Kelescope.Boot.Loader.versions() |> IO.inspect()"` est la
commande de diagnostic, à documenter dans
`docs/maintenance/paquet-rpm.md`.

## Invariants

Aucun compilateur ne les vérifie seul. Les contrôles associés sont décrits plus
bas.

1. **Aucun `defimpl` hors de `kelescope_core`.** La consolidation de protocoles
   est globale et vit dans le paquet runtime. Un type défini par une partie et
   passé à un protocole consolidé lève `Protocol.UndefinedError`.
2. **Tous les assets dans `kelescope_core`.** Tailwind produit un `app.css`
   unique en scannant les templates de toutes les applications. `phx.digest`
   produit un `cache_manifest.json` unique.
3. **Toutes les traductions dans `kelescope_core`.** Le backend
   `KelescopeWeb.Gettext` compile les traductions du projet entier.
4. **Toutes les routes dans `kelescope_core`.** Une route nouvelle impose une
   livraison du socle.
5. **Aucune configuration compile-time dans une partie.** `sys.config` et
   `runtime.exs` sont dans le paquet runtime. Les réglages d'une partie passent
   par les valeurs par défaut de son `.app`, surchargées par des variables lues
   dans `kelescope.env`.
6. **Les versions OTP restent figées.** Elles ne bougent qu'à une rupture de
   contrat entre le socle et les parties.

## Étapes de livraison

Chaque étape est livrable seule.

### Étape 1 — le socle et le chargeur

Création de `kelescope_boot`. Passage en umbrella avec deux applications :
`kelescope_boot` et `kelescope`, cette dernière inchangée dans son contenu.
`kelescope` sort du `.rel` et s'installe dans `plugins/`.

Le spec produit `kelescope`, `kelescope-runtime` et `kelescope-app`.

Aucun découpage fonctionnel à ce stade. Une livraison passe de 7,6 Mo à environ
250 Ko. C'est là que se prend l'essentiel du gain de poids, et c'est l'étape qui
éprouve le mécanisme en conditions réelles avant tout refactoring.

`docs/maintenance/paquet-rpm.md` est réécrit.

### Étape 2 — le rechargement à chaud

`bin/kelescope-reload-plugin`, `Kelescope.Boot.Loader.reload/1`,
`Kelescope.Boot.Loader.versions/0`, les `%posttrans` et `%postun`.

`docs/maintenance/paquet-rpm.md` gagne la procédure de mise à jour partielle et
la commande de diagnostic.

### Étape 3 — la découpe en quatre applications

`kelescope` devient `kelescope_core`, `kelescope_monitor`, `kelescope_domaines`
et `kelescope_mcu`. Les trois pollers passent sous la supervision de leur
partie. Le spec gagne trois sous-paquets.

C'est l'étape la plus lourde en refactoring, et celle dont le gain marginal est
le plus faible une fois les deux premières livrées.

## Points établis

Éprouvés sur une release jetable, avec Erlang/OTP 26 et Elixir 1.18.3, en mode
`embedded`. Chaque ligne cite ce qui a été observé.

| Point | Résultat |
|---|---|
| Un `primLoad` portant sur un module absent du disque | Le nœud ne démarre pas : `Runtime terminating during boot ({load_failed,['Elixir.Boot.Report']})`, code de sortie 1. |
| Un module déposé dans un `ebin` de la release mais absent du `primLoad` | `UndefinedFunctionError` à l'appel. Le mode `embedded` ne charge rien à la demande. |
| Une application non dépendante de l'application principale | Absente du `.rel` produit par `mix release`. |
| Les protocoles consolidés, atteints depuis un module chargé de `plugins/` | Atteints. `:code.which(Jason.Encoder)` pointe vers `releases/<abi>/consolidated`, et `Jason.encode!/1` fonctionne depuis le plugin. |
| Une struct définie par un plugin, passée à un protocole consolidé | `Protocol.UndefinedError`. C'est le fondement de l'invariant 1. |
| Le chargement explicite des modules d'un plugin | Obligatoire. Sans lui, `ensure_all_started/1` échoue sur `{:bad_return, … {:EXIT, {:undef, [{PlugA.Application, :start, …}]}}}`. |
| `Application.ensure_all_started/1` appelé depuis `start/2` | Blocage sans fin. Processus tué au bout de 45 s. |
| La même séquence exécutée depuis un `handle_continue/2` | Fonctionne. Les plugins démarrent, leurs processus supervisés tournent. |
| `reload/1` sur une partie modifiée, nœud en marche | Le nouveau code répond, un module ajouté est chargé, un module supprimé est purgé et devient introuvable, le processus supervisé redémarre. La durée de fonctionnement du nœud n'est pas remise à zéro : pas de redémarrage. |
| Les trois branches de `kelescope-reload-plugin` | Nominale, service arrêté, et repli sur `try-restart` quand le nœud est injoignable : les trois se comportent comme prévu. |

## Reste à éprouver

- `bin/kelescope rpc` lancé depuis un vrai `%posttrans`, sur EL9, avec
  `kelescope.env` sourcé. Le script a été éprouvé hors du contexte rpm
  seulement.
- La totalité de la chaîne avec Phoenix et LiveView. Le jet jetable ne portait
  ni endpoint ni vue.

## Tests

- Chargeur : sur un répertoire de plugins factice, vérifier l'ajout au code
  path, le chargement des modules, l'ordre de démarrage, et l'échec explicite
  sur une application illisible.
- Rechargement : charger une partie, remplacer ses `.beam` par une version qui
  renvoie une autre valeur, appeler `reload/1`, vérifier la nouvelle valeur.
  Vérifier aussi le cas d'un module supprimé et celui d'un module ajouté.
- Invariant 1 : parcourir les `.beam` des applications hors socle et échouer si
  l'un exporte `__impl__/1`. Ce test échoue bien si un `defimpl` est ajouté à
  une partie.
- Charge utile de la release : échouer si l'ensemble des dépendances hex
  déclarées par les parties n'est pas couvert par celles de `kelescope_boot`.
- Suite existante : elle tourne depuis la racine de l'umbrella, sans
  régression.
- Bout en bout, sur une machine EL9 : installer les paquets, démarrer le
  service, atteindre `/`, `/domains` et `/mcu`.

## Critères d'acceptation

1. `dnf install ./kelescope-*.rpm` installe l'ensemble, le service démarre, les
   trois pages répondent.
2. Deux builds qui ne diffèrent que par le code d'une partie produisent un
   `/opt/kelescope` identique hors `plugins/`.
3. Mettre à jour une partie seule, service en marche, la recharge sans
   redémarrer le nœud. La durée de fonctionnement du nœud le prouve. La page
   concernée sert la nouvelle version, les autres ne sont pas interrompues.
4. Retirer `kelescope-mcu` laisse `/` et `/domains` en service.
5. `bin/kelescope rpc` affiche les applications chargées, leur ABI et leur
   version produit.
6. Un plugin illisible ou incomplet fait échouer le démarrage avec un message
   nommant l'application. Aucun démarrage partiel silencieux.
7. Le build signale que `kelescope-core` doit être livré dès que le condensat
   des assets ou l'ensemble des `msgid` change.

## Hors périmètre

- Les mises à jour OTP `appup` et `relup`. Voir ADR-002.
- Un dépôt et un spec par partie. Voir ADR-002.
- La haute disponibilité par deux instances.
- L'enregistrement dynamique de routes par une partie.
- La préservation de l'état d'un LiveView ouvert pendant un rechargement.
- Le chargement d'une partie sans redémarrage ni rechargement, à chaud, sur un
  nœud qui ne la connaissait pas encore.

## Risques

- **Une classe CSS absente du socle installé ne produit aucune erreur.** Elle
  produit un affichage faux. C'est le risque le plus discret du lot. Le contrôle
  de condensat au build le couvre au moment de la livraison, pas au moment du
  déploiement.
- **Un mélange de versions jamais éprouvé ensemble.** Les `>=` autorisent des
  combinaisons que personne n'a testées. Le relèvement manuel des versions
  minimales est la seule protection, et il repose sur la vigilance.
- **La liste des dépendances hex est déclarée deux fois**, dans les parties et
  dans `kelescope_boot`. Le test de couverture la garde alignée.
- **La configuration reste dans le paquet runtime.** Une partie qui aurait
  besoin d'une clé de configuration compile-time nouvelle imposerait une
  livraison du runtime. L'invariant 5 l'interdit ; il faudra s'y tenir.
- **Le comportement avec Phoenix et LiveView n'est pas éprouvé.** Le jet
  jetable a validé le mécanisme sur des modules simples. L'étape 1 est le
  premier test réel.
