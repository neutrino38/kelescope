# Découpage du paquet RPM

## Objectif

Livrer une correction de kelescope sans expédier 7,6 Mo, et sans couper le
service.

Le paquet est découpé en un socle runtime et quatre applications OTP installées
hors de la release. Un chargeur les monte au démarrage. Une mise à jour d'une
partie recharge ses modules dans le nœud en marche.

Décisions : [ADR-002](../../architecture/adr-002-decoupage-paquets-rpm.md) pour
le découpage, [ADR-003](../../architecture/adr-003-backend-gettext-par-partie.md)
pour les traductions.

## Contraintes mesurées

`releases/<abi>/start.script` précharge la liste exacte des modules de chaque
application citée dans le `.rel`, par une directive `primLoad`, et le nœud tourne
en mode `embedded`. Une application citée dans le boot script n'est donc pas
remplaçable seule. L'option `:none` de `mix release` ne lève pas cette
contrainte : `iex` est déclaré `none` et reste préchargé.

C'est pourquoi aucune application de kelescope ne figure dans le `.rel`.

## Architecture

### Arborescence installée

```
/opt/kelescope/
├── erts-14.2.5/                        ┐
├── lib/<dépendances>/                  │
├── releases/1.0.0/                     ├─ kelescope-runtime
├── bin/kelescope                       │
├── bin/kelescope-reload-plugin         ┘
└── plugins/
    ├── kelescope_core-1.0.0/{ebin,priv}       ─ kelescope-core
    ├── kelescope_monitor-1.0.0/{ebin,priv}    ─ kelescope-monitor
    ├── kelescope_domaines-1.0.0/{ebin,priv}   ─ kelescope-domaines
    └── kelescope_mcu-1.0.0/{ebin,priv}        ─ kelescope-mcu
```

`bin/kelescope`, `/opt/kelescope`, l'unité systemd et
`/etc/kelescope/kelescope.env` ne changent pas. L'exploitant ne voit aucune
différence de procédure.

### Le chargeur `kelescope_boot`

`kelescope_boot` est l'application principale de la release, qui garde le nom
`kelescope`. Il ne contient que le chargeur. Son `mix.exs` déclare en revanche
**toutes les dépendances hex** du projet : c'est lui qui décide de la charge
utile embarquée.

Le répertoire des plugins vaut `<RELEASE_ROOT>/plugins`, surchargeable par
`KELESCOPE_PLUGINS_DIR` pour le développement et les tests.

Séquence de chargement, dans cet ordre :

1. lister `plugins/*/ebin`, et `:code.add_pathz/1` sur chacun ;
2. pour chaque application, mémoriser `Application.get_all_env/1`, puis
   `Application.load/1` ;
3. pour chaque application, charger explicitement les modules listés dans la
   clé `modules` de son fichier `.app`, par `:code.load_file/1` ;
4. `Application.ensure_all_started/1` sur chaque application chargée.

L'étape 2 mémorise la configuration avant le chargement. À ce moment, cette
table ne contient que ce que `runtime.exs` a posé. `Application.load/1` conserve
ces valeurs, mais `Application.unload/1` les efface. Sans cette mémorisation, un
rechargement à chaud viderait la configuration issue de `runtime.exs` :
`secret_key_base`, le port HTTPS, les chemins de certificat.

L'étape 3 n'est pas une optimisation. Sans elle, l'étape 4 échoue sur un `undef`
de `<Application>.start/2` : en mode `embedded`, rien ne se charge à la demande,
et les modules d'un plugin ne figurent dans aucun `primLoad`. Ce mode est
conservé volontairement. Un module manquant se signale au démarrage, pas six
heures plus tard.

L'étape 4 laisse OTP résoudre l'ordre à partir des dépendances déclarées.
`kelescope_core` démarre donc avant les autres.

**La séquence ne s'exécute pas depuis `start/2`.** Appeler
`Application.ensure_all_started/1` depuis la fonction `start/2` d'une autre
application bloque sans fin : le contrôleur d'applications d'OTP est occupé à
démarrer l'appelant. `kelescope_boot` supervise donc `Kelescope.Boot.Starter`,
dont `init/1` retourne `{:ok, state, {:continue, :load_plugins}}`.

Un échec à l'une des quatre étapes arrête le nœud avec un message nommant
l'application et la cause. Pas de démarrage partiel silencieux.

### Gel des versions OTP

Les cinq applications portent la version OTP `1.0.0`, figée. C'est un numéro
d'ABI : le contrat interne entre le socle et les parties. Il ne bouge qu'à une
rupture de ce contrat.

La version produit vit uniquement dans le champ `Version` du RPM. Chaque
application l'expose dans son environnement applicatif sous la clé `:build`, lue
depuis `KELESCOPE_BUILD_VERSION` à la compilation.

### Les quatre applications

| Application | Contenu |
|---|---|
| `kelescope_core` | `Endpoint`, `Router`, `Layouts`, `CoreComponents`, `Gettext`, `Telemetry`, `ErrorHTML`, `ErrorJSON`, `LocaleController`, `LocaleHook`, `Kelixip.Link`, `Kelixip.Control`, `Kelixip.DomainsLink`, et tous les assets |
| `kelescope_monitor` | `ScenarioMonitorLive`, `Kelixip.StatusPoller` |
| `kelescope_domaines` | `DomainListLive` |
| `kelescope_mcu` | `McuLive`, `Kelixip.ConferencesPoller` |

`Kelixip.DomainsLink` est dans le socle parce que deux pages le consomment,
`/domains` et `/mcu`. C'est la règle : **un lien kelixip servi à plus d'une page
appartient au socle.** `kelescope_domaines` n'a donc plus de processus à
superviser et n'est pas une application OTP démarrable.

Le routeur reste dans le socle et route vers des modules livrés par d'autres
paquets. Le macro `live/4` de LiveView engendre une vérification à la
compilation : le routeur déclare donc
`@compile {:no_warn_undefined, [...]}` pour les trois vues, absentes à la
compilation du socle et présentes à l'exécution.

Le projet est un umbrella : `apps/kelescope_boot`, `apps/kelescope_core`,
`apps/kelescope_monitor`, `apps/kelescope_domaines`, `apps/kelescope_mcu`.

## Découpage des sous-paquets RPM

Un seul fichier spec, `rpm/kelescope.spec`. Tailles mesurées en `0.2.0-1.el9`.

| Paquet | Contenu | Taille |
|---|---|---|
| `kelescope` | méta-paquet, aucun fichier | 7,0 Ko |
| `kelescope-runtime` | ERTS, dépendances, `releases/`, `bin/`, unité systemd, `kelescope.env` | 7360,6 Ko |
| `kelescope-core` | `plugins/kelescope_core-1.0.0` | 335,7 Ko |
| `kelescope-monitor` | `plugins/kelescope_monitor-1.0.0` | 62,5 Ko |
| `kelescope-domaines` | `plugins/kelescope_domaines-1.0.0` | 57,6 Ko |
| `kelescope-mcu` | `plugins/kelescope_mcu-1.0.0` | 95,5 Ko |

Règles de dépendances :

- les quatre parties portent `Requires: kelescope-runtime >= %{min_runtime}` ;
- les trois pages portent en plus `Requires: kelescope-core >= %{min_core}` ;
- le méta-paquet porte un `Requires: … >=` sur chacun des cinq autres.

Toujours `>=`, jamais une égalité stricte. Une égalité stricte empêcherait la
mise à jour d'une seule partie, c'est-à-dire tout l'intérêt du découpage.

Les versions minimales se relèvent à la main, dans le spec, quand une partie
commence à employer une nouveauté du socle.

Les scriptlets de service — création du compte `kelixip`, macros systemd, invite
interactive de première installation — sont dans `kelescope-runtime`.

## Construction

`%build` compile l'umbrella, construit les assets, puis produit la release.
`mix release` n'embarque que `kelescope_boot` et les dépendances hex.

`%install` copie ensuite, pour chaque partie, **uniquement `ebin/` et `priv/`**
depuis `_build/prod/lib/<application>/` vers
`/opt/kelescope/plugins/<application>-1.0.0/`, avec `cp -aL` : `priv` est un lien
symbolique dans `_build`, et une copie sans `-L` livrerait un paquet sans assets
ni traductions. Le répertoire `consolidated/` produit par la compilation ne doit
pas être copié : les protocoles consolidés de la release vivent dans
`releases/1.0.0/consolidated`.

## Rechargement à chaud

`bin/kelescope-reload-plugin <application>`, livré par `kelescope-runtime` :

1. sort en succès si le service n'est pas actif ;
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
   disque ;
4. réapplique les surcharges mémorisées au chargement, que `unload` vient
   d'effacer ;
5. `:code.purge/1` puis `:code.delete/1` sur les modules disparus ;
6. `:code.purge/1` puis `:code.load_file/1` sur chaque module de la nouvelle
   liste ;
7. `Application.ensure_all_started/1`.

Le `%posttrans` de chaque paquet de partie appelle le script. Le `%postun`, en
cas de désinstallation, appelle `systemctl try-restart kelescope`.

Limite assumée : les processus LiveView tournent sous la supervision de
`kelescope_core`. `:code.purge/1` sur un module de page tue donc les onglets
ouverts sur cette page, et le client remonte. Les autres pages ne bougent pas.

## Version réellement chargée

`Kelescope.Boot.Loader.versions/0` retourne, pour chaque application, sa version
d'ABI et sa version produit :

```
/opt/kelescope/bin/kelescope rpc "Kelescope.Boot.Loader.versions() |> IO.inspect()"
```

## Invariants

1. **Aucun `defimpl` hors de `kelescope_core`.** La consolidation de protocoles
   est globale et vit dans le paquet runtime. Un type défini par une partie et
   passé à un protocole consolidé lève `Protocol.UndefinedError`. Un test le
   vérifie sur les `.beam` livrés.
2. **Tous les assets dans `kelescope_core`.** `app.css` et `app.js` sont uniques.
   Le CSS du socle doit donc déclarer un `@source` vers le `lib` de chaque
   partie, et importer le `phoenix-colocated/<application>` de chacune. Sans
   cela, une classe employée par une page seule est absente du bundle, sans
   aucune erreur.
3. **Les traductions suivent leur partie.** Voir
   [ADR-003](../../architecture/adr-003-backend-gettext-par-partie.md). La langue
   se pose globalement, par `Gettext.put_locale/1`.
4. **Toutes les routes dans `kelescope_core`.** Une route nouvelle impose une
   livraison du socle.
5. **Aucune configuration compile-time dans une partie.** `sys.config` et
   `runtime.exs` sont dans le paquet runtime. Chaque application a son propre
   espace de configuration, du nom de l'application.
6. **Les versions OTP restent figées.**

## Points établis

Éprouvés avec Erlang/OTP 26 et Elixir 1.18.3, en mode `embedded`.

| Point | Résultat |
|---|---|
| Un `primLoad` portant sur un module absent du disque | Le nœud ne démarre pas : `Runtime terminating during boot ({load_failed,...})`, code de sortie 1. |
| Un module déposé dans un `ebin` de la release mais absent du `primLoad` | `UndefinedFunctionError` à l'appel. Le mode `embedded` ne charge rien à la demande. |
| Une application non dépendante de l'application principale | Absente du `.rel` produit par `mix release`. Vérifié sur la release livrée : elle ne contient que `kelescope_boot` et les dépendances. |
| Les protocoles consolidés, atteints depuis un module chargé de `plugins/` | Atteints. `:code.which(Jason.Encoder)` pointe vers `releases/<abi>/consolidated`. |
| Une struct définie par un plugin, passée à un protocole consolidé | `Protocol.UndefinedError`. Fondement de l'invariant 1. |
| Le chargement explicite des modules d'un plugin | Obligatoire. Sans lui, `ensure_all_started/1` échoue sur un `undef` de `<App>.start/2`. |
| `Application.ensure_all_started/1` appelé depuis `start/2` | Blocage sans fin. Processus tué au bout de 45 s. |
| `Application.load/1` sur une application déjà configurée | Les valeurs posées sont conservées : `runtime.exs` peut configurer une partie avant son chargement. |
| `Application.unload/1` | Vide la configuration. `reload/1` doit réappliquer les surcharges mémorisées. |
| `priv` dans `_build/prod/lib/<application>/` | Lien symbolique. La copie vers `plugins/` doit le dérouler (`cp -aL`). |
| Deux constructions successives de `kelescope-runtime` | 2 fichiers diffèrent sur 1552 : `releases/COOKIE`, régénéré par `mix release`, et un `.beam` non reproductible d'une dépendance. Aucun fichier de kelescope. |
| Démarrage depuis les six paquets | Les quatre applications sont montées, l'endpoint sert en HTTPS, `/`, `/domains` et `/mcu` répondent 200, les assets digérés sont servis. |
| Rechargement de la seule partie `kelescope_mcu`, service en marche | `/mcu` sert le nouveau code, `/` et `/domains` ne sont pas interrompues, la durée de fonctionnement du nœud passe de 35 s à 40 s sans remise à zéro. |
| Les trois branches de `kelescope-reload-plugin` | Nominale, service arrêté, et repli sur `try-restart` : les trois se comportent comme prévu. |
| Retrait de `kelescope-mcu` | `/` et `/domains` répondent 200. `/mcu` répond 500 : la route existe dans le socle, la vue non. |
| `app.css` après la découpe | Identique à l'octet près à celui d'avant la découpe (71 037 octets), classes des pages comprises. |

## Reste à éprouver

- Le déclenchement du rechargement par rpm lui-même. `%posttrans` et `%postun`
  sont dans le paquet, mais le script a été lancé à la main.
- L'installation par `dnf` sur une machine EL9, et le service systemd.

## Tests

- Chargeur : ajout au code path, chargement des modules, démarrage, conservation
  de la configuration, et échec explicite sur une application illisible.
- Rechargement : nouveau code pris en compte, module ajouté chargé, module
  supprimé purgé, configuration restaurée, application redémarrée.
- Invariant 1 : parcourir les `.beam` des parties hors socle et échouer si l'un
  exporte `__impl__/1`.
- Charge utile de la release : échouer si une partie dépend d'une application
  absente de la fermeture de `kelescope_boot`.
- Langue : une page sert l'anglais pour ses propres chaînes **et** pour celles du
  socle. Ce test échoue si la langue est posée par backend.

## Critères d'acceptation

1. Installer les six paquets, démarrer le service, les trois pages répondent.
2. `kelescope-runtime` ne contient aucun fichier de `/opt/kelescope/plugins`.
   Une reconstruction du socle n'est pas reproductible au bit près :
   `releases/COOKIE` et certains `.beam` de dépendances bougent.
3. Mettre à jour une partie seule, service en marche, la recharge sans
   redémarrer le nœud. Les autres pages ne sont pas interrompues.
4. Retirer `kelescope-mcu` laisse `/` et `/domains` en service.
5. `bin/kelescope rpc` affiche les applications chargées, leur ABI et leur
   version produit.
6. Un plugin illisible fait échouer le démarrage avec un message nommant
   l'application.
7. Le build signale que `kelescope-core` doit être livré dès que le condensat
   des assets change.

Le point 7 n'est pas implémenté : le contrôle de condensat au build reste à
faire.

## Hors périmètre

- Les mises à jour OTP `appup` et `relup`. Voir ADR-002.
- Un dépôt et un spec par partie. Voir ADR-002.
- La haute disponibilité par deux instances.
- L'enregistrement dynamique de routes par une partie.
- La préservation de l'état d'un LiveView ouvert pendant un rechargement.
- Le chargement d'une partie que le nœud ne connaissait pas encore, sans
  redémarrage.

## Risques

- **Une classe CSS absente du socle installé ne produit aucune erreur.** Elle
  produit un affichage faux. Le contrôle de condensat au build (critère 7) reste
  à écrire ; en attendant, livrer `kelescope-core` avec toute page dont le style
  change.
- **`/mcu` répond 500 si `kelescope-mcu` est absent.** La route vit dans le
  socle, la vue non. Une page d'erreur explicite serait préférable.
- **Un mélange de versions jamais éprouvé ensemble.** Les `>=` autorisent des
  combinaisons que personne n'a testées. Le relèvement manuel des versions
  minimales est la seule protection.
- **La liste des dépendances hex est déclarée deux fois**, dans les parties et
  dans `kelescope_boot`. Le test de charge utile la garde alignée.
- **`releases/COOKIE` change à chaque construction du socle.** Réinstaller
  `kelescope-runtime` change le cookie Erlang par défaut du nœud. Fixer
  `RELEASE_COOKIE` dans `kelescope.env` si ce mouvement pose problème.
