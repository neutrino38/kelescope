# Paquets RPM

kelescope est livré en six paquets.

| Paquet | Contenu | Taille |
|---|---|---|
| `kelescope` | Méta-paquet. Aucun fichier. Il tire les cinq autres. | 7 Ko |
| `kelescope-runtime` | Le socle d'exécution : runtime Erlang, dépendances, script de démarrage, service systemd, fichier de configuration. | 7,4 Mo |
| `kelescope-core` | Le socle applicatif : endpoint, routeur, composants, assets, liens kelixip. | 336 Ko |
| `kelescope-monitor` | La page de supervision des scénarios (`/`). | 63 Ko |
| `kelescope-domaines` | La page des domaines (`/domains`). | 58 Ko |
| `kelescope-mcu` | La page MCU (`/mcu`). | 96 Ko |

Corriger la page MCU n'expédie donc que 96 Ko, au lieu des 7,6 Mo d'un paquet
unique.

Décisions et conception :
[ADR-002](../architecture/adr-002-decoupage-paquets-rpm.md),
[ADR-003](../architecture/adr-003-backend-gettext-par-partie.md),
[SPEC](../conception/decoupage-rpm/SPEC.md).

## Arborescence installée

```
/opt/kelescope/
├── erts-14.2.5/        ┐
├── lib/                ├─ kelescope-runtime
├── releases/           │
├── bin/kelescope       ┘
└── plugins/
    ├── kelescope_core-1.0.0/      ─ kelescope-core
    ├── kelescope_monitor-1.0.0/   ─ kelescope-monitor
    ├── kelescope_domaines-1.0.0/  ─ kelescope-domaines
    └── kelescope_mcu-1.0.0/       ─ kelescope-mcu
```

Le socle d'exécution démarre un chargeur. Au démarrage, ce chargeur monte toutes
les applications présentes dans `/opt/kelescope/plugins`, puis les lance.

`1.0.0` est un numéro d'ABI, c'est-à-dire le contrat interne entre le socle et
les pages. Il est figé : il ne suit pas la version produit, qui vit dans le
champ `Version` du RPM. Ne pas le confondre avec la version affichée par
`rpm -q kelescope-mcu`.

## Construire les paquets

Prérequis sur la machine de build : `elixir` (≥ 1.17) dans le `PATH`,
`erlang` (≥ 26, paquet RPM), `rpmbuild`, et un accès réseau à hex.pm, GitHub
et npmjs.org. Elixir n'existe pas comme paquet RPM pour EL9 : la version
installée est vérifiée au début de la section `%build` du spec (pas via
`BuildRequires`, que rpmbuild ne peut valider que contre la base RPM).

```
./rpm/build.sh
```

Le script archive l'arbre de travail courant, puis appelle `rpmbuild`. Les
trois paquets sont déposés dans le répertoire depuis lequel `build.sh` a été
lancé, et l'arborescence de build (`rpm/build/`) est supprimée.

La version produit se lit dans le champ `Version` de `rpm/kelescope.spec`, et
nulle part ailleurs. Les fichiers `mix.exs` portent des versions d'ABI figées,
qu'il ne faut pas relever pour une livraison ordinaire.

L'étape de build télécharge les dépendances Elixir (hex.pm) et les binaires
autonomes de tailwind et esbuild (GitHub, npmjs.org). Un environnement de build
isolé du réseau (mock, koji) ne peut pas construire ces paquets tels quels ; il
faut soit lui donner un accès à ces trois domaines, soit pré-construire ailleurs
(`MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release`) et adapter la
section `%build` du spec.

Deux constructions successives du socle ne sont pas identiques au bit près :
`releases/COOKIE` est régénéré par `mix release`, et certains `.beam` de
dépendances ne sont pas reproductibles. Réinstaller `kelescope-runtime` change
donc le cookie Erlang par défaut du nœud. Fixer `RELEASE_COOKIE` dans
`kelescope.env` si ce mouvement pose problème.

## Installer

```
dnf install ./kelescope-*.rpm
```

L'installation crée un compte système `kelixip` (sans shell de connexion)
s'il n'existe pas déjà — c'est aussi sous ce compte que tourne kelixip
lui-même — dépose le service systemd, et un fichier de configuration
`/etc/kelescope/kelescope.env` (root:kelixip, mode 640, `%config(noreplace)`
donc jamais écrasé par une mise à jour). Le service n'est pas démarré
automatiquement : il faut d'abord le configurer.

Si `KELIXIP_NODE` n'est pas encore renseigné dans ce fichier (première
installation), et que le terminal est interactif, l'installation demande
le nom Erlang du nœud kelixip à surveiller (ex.
`kelixip@host.example.org`) et l'écrit dans `kelescope.env`. Une réponse
vide, ou une installation sans terminal interactif (dnf en mode
non-interactif, Ansible, etc.), laisse `KELIXIP_NODE` vide et affiche un
rappel de l'endroit où le renseigner. Cette invite ne se déclenche qu'à
l'installation initiale, jamais lors d'une mise à jour.

De même, si `KELESCOPE_SSL_CERTFILE` ou `KELESCOPE_SSL_KEYFILE` pointent
vers des fichiers absents ou illisibles (le cas dès la première
installation, avant que les certificats ne soient déposés), et que le
terminal est interactif, l'installation demande le chemin du certificat
puis celui de la clé privée. Une réponse vide sur l'une des deux
questions garde le chemin déjà présent dans `kelescope.env`. Sans terminal
interactif, ou si les chemins renseignés restent invalides, l'installation
affiche un rappel plutôt que d'échouer.

## Configurer

Toute la configuration passe par `/etc/kelescope/kelescope.env`, chargé
par systemd (`EnvironmentFile=`).

| Variable | Rôle |
|---|---|
| `PHX_HOST` | Nom d'hôte public, utilisé pour générer les URLs. |
| `SECRET_KEY_BASE` | Secret de signature des sessions. Au moins 64 caractères, sinon le service démarre mais renvoie une erreur 500 sur chaque requête. Générer avec `openssl rand -base64 48`, directement sur la machine cible (voir remarque sur le copier-coller ci-dessous). |
| `RELEASE_NODE` | Identité du nœud Erlang de kelescope (nom long, ex. `kelescope@host.example.org`). Nécessite `RELEASE_DISTRIBUTION=name`. |
| `RELEASE_DISTRIBUTION` | Mode de distribution Erlang. À positionner à `name` : une release Elixir démarre par défaut en noms courts (`sname`), incompatible avec un `RELEASE_NODE` en nom long ou en adresse IP. Sans cette variable, le service ne démarre pas (`net_kernel` échoue avec `nodistribution`). |
| `RELEASE_COOKIE` | Cookie Erlang du nœud kelescope lui-même. Laissé vide, la valeur par défaut vient de `releases/COOKIE`, régénéré à chaque construction du socle. À renseigner si cette valeur doit rester stable, ou si plusieurs nœuds kelescope doivent partager une identité. |
| `KELIXIP_NODE` | Nœud kelixip à surveiller (nom long). |
| `KELIXIP_COOKIE` | Cookie Erlang partagé avec ce nœud kelixip, le même que celui utilisé par `kelictl`. Doit être identique octet pour octet à celui du nœud kelixip (voir remarque sur le copier-coller ci-dessous) : la moindre différence, même invisible, fait échouer la connexion avec `Invalid challenge reply` dans le journal de kelixip. |
| `KELESCOPE_HTTPS_PORT` | Port HTTPS d'écoute (8443 par défaut). |
| `KELESCOPE_SSL_CERTFILE` | Chemin du certificat (ou de la chaîne) PEM servi. |
| `KELESCOPE_SSL_KEYFILE` | Chemin de la clé privée PEM correspondante. |

`kelescope` doit joindre le nœud kelixip par la distribution Erlang : le
réseau entre les deux hôtes doit autoriser EPMD (port 4369/tcp) et la
plage de ports de distribution BEAM (voir
[ADR-001](../architecture/adr-001-connexion-kelixip.md)).

`SECRET_KEY_BASE` et `KELIXIP_COOKIE` sont sensibles à un simple
copier-coller depuis un éditeur externe : un retour chariot Windows
(`\r`) ou un caractère perdu en fin de valeur ne se voit pas à l'écran
mais casse quand même la vérification. Générer et écrire ces valeurs en
une seule commande shell exécutée sur la machine cible, sans passer par
le presse-papiers :

```
NEW_SECRET=$(openssl rand -base64 48)
sed -i '/^SECRET_KEY_BASE=/d' /etc/kelescope/kelescope.env
echo "SECRET_KEY_BASE=${NEW_SECRET}" >> /etc/kelescope/kelescope.env
```

Pour vérifier après coup qu'une valeur ne contient pas de caractère
parasite :

```
grep '^SECRET_KEY_BASE=' /etc/kelescope/kelescope.env | cat -A
```

Un `^M` avant le `$` de fin de ligne signale un `\r` à supprimer.

## Fournir les certificats TLS

`KELESCOPE_SSL_CERTFILE` et `KELESCOPE_SSL_KEYFILE` doivent pointer vers
des fichiers PEM lisibles par le compte `kelixip` :

```
install -d -m 750 -o root -g kelixip /etc/kelescope/tls
install -m 640 -o root -g kelixip mon-certificat.pem /etc/kelescope/tls/kelescope.crt
install -m 640 -o root -g kelixip ma-cle.pem         /etc/kelescope/tls/kelescope.key
```

- `KELESCOPE_SSL_CERTFILE` doit contenir le certificat serveur suivi, le
  cas échéant, des certificats intermédiaires (chaîne complète, dans cet
  ordre).
- `KELESCOPE_SSL_KEYFILE` doit contenir la clé privée non chiffrée
  correspondante (une clé protégée par mot de passe empêcherait le
  démarrage sans interaction).
- Un certificat émis par une autorité interne à IVèS ou un certificat
  Let's Encrypt conviennent tous les deux ; seul le format PEM et les
  permissions ci-dessus comptent.
- Ne pas faire pointer `KELESCOPE_SSL_CERTFILE`/`KELESCOPE_SSL_KEYFILE`
  directement vers `/etc/letsencrypt/live/<domaine>/` : ces fichiers
  restent en `root:root`, mode 600, illisibles par `kelixip` (le service
  démarre mais s'arrête aussitôt, `journalctl -u kelescope` affiche
  `Runtime terminating during boot` sans détail). Copier systématiquement
  `fullchain.pem` et `privkey.pem` vers `/etc/kelescope/tls/` avec les
  droits ci-dessus.
- Après renouvellement d'un certificat, redémarrer le service pour qu'il
  soit repris en compte : `systemctl restart kelescope`. Avec un
  certificat Let's Encrypt, ajouter un hook de déploiement certbot
  (`/etc/letsencrypt/renewal-hooks/deploy/kelescope.sh`) qui refait la
  copie ci-dessus puis exécute `systemctl restart kelescope` : sans lui,
  le renouvellement automatique (tous les ~60 jours) ne met pas à jour
  `/etc/kelescope/tls/`.

## Démarrer et vérifier

```
systemctl enable --now kelescope
systemctl status kelescope
journalctl -u kelescope -f
```

Au démarrage, le chargeur écrit dans le journal la liste des applications
qu'il a montées :

```
[info] kelescope: applications chargées [:kelescope_core, :kelescope_domaines, :kelescope_mcu, :kelescope_monitor]
```

Une application absente de cette liste signale que son paquet n'est pas
installé.

Le service écrit ses journaux sur la sortie standard, capturée par
journald : aucune rotation de fichier de log à gérer.

Symptômes fréquents dans `journalctl -u kelescope` :

| Message | Cause |
|---|---|
| `failed_to_start_child,net_kernel,{'EXIT',nodistribution}` | `RELEASE_DISTRIBUTION=name` absent, voir la table des variables. |
| `Runtime terminating during boot` (sans autre détail) | Le plus souvent `KELESCOPE_SSL_CERTFILE`/`KELESCOPE_SSL_KEYFILE` illisible par `kelixip`, voir la section certificats. |
| `plugin kelescope_… : module … illisible` | Le paquet de cette partie est incomplet ou corrompu. Le nœud refuse de démarrer plutôt que de tourner amputé. Réinstaller le paquet. |
| Une page répond 500, les autres répondent | Le paquet de cette page n'est pas installé. La route vit dans `kelescope-core`, la vue dans son propre paquet. |
| `cookie store expects conn.secret_key_base to be at least 64 bytes` | `SECRET_KEY_BASE` fait moins de 64 caractères (souvent un caractère perdu au copier-coller). |
| `kelixip link to <nœud>: :connect_failed` | À corréler avec `journalctl -u kelixip` sur l'autre hôte. `Invalid challenge reply` : `KELIXIP_COOKIE` ne correspond pas au cookie du nœud kelixip. Pas de message de rejet côté kelixip : vérifier le réseau (EPMD 4369/tcp et port de distribution BEAM, voir ADR-001) et que `KELIXIP_NODE` correspond exactement au nom et à l'adresse du nœud kelixip (`ps -eo cmd | grep beam.smp` sur l'hôte kelixip donne son `-name` et son `-setcookie` réels). |

## Mettre à jour ou désinstaller

Mise à jour complète :

```
dnf upgrade ./kelescope-*.rpm
```

Mise à jour d'une seule page, quand le socle n'a pas changé :

```
dnf upgrade ./kelescope-mcu-<version>-1.el9.x86_64.rpm
```

Le service n'est pas redémarré. En fin de transaction, rpm appelle
`/opt/kelescope/bin/kelescope-reload-plugin`, qui recharge les modules dans le
nœud en marche : les autres pages ne sont pas interrompues.

Trois cas, tous sûrs :

- service arrêté : le script ne fait rien, le nouveau code sera pris au
  prochain démarrage ;
- nœud injoignable ou rechargement en échec : le script bascule sur
  `systemctl try-restart kelescope` et l'écrit sur la sortie d'erreur ;
- rechargement réussi : le script affiche la liste des modules chargés.

Un onglet déjà ouvert sur la page rechargée se remonte tout seul : le
processus LiveView qui exécutait l'ancien code est tué, et le navigateur se
reconnecte. Les onglets ouverts sur les autres pages ne bougent pas.

Attention au style : `app.css` et `app.js` sont uniques et vivent dans
`kelescope-core`. Une page dont le style change doit être livrée **avec**
`kelescope-core`, sinon la classe manquante ne produit aucune erreur, juste un
affichage faux.

## Savoir ce qui tourne

Le numéro de version du RPM ne décrit plus l'ensemble : une machine peut porter
un socle et une application de versions différentes.

```
/opt/kelescope/bin/kelescope rpc "Kelescope.Boot.Loader.versions() |> IO.inspect()"
```

```
%{
  kelescope_boot: %{build: "0.2.0-1.el9", abi: "1.0.0"},
  kelescope_core: %{build: "0.2.0-1.el9", abi: "1.0.0"},
  kelescope_monitor: %{build: "0.2.0-1.el9", abi: "1.0.0"},
  kelescope_domaines: %{build: "0.2.0-1.el9", abi: "1.0.0"},
  kelescope_mcu: %{build: "0.2.0-1.el9", abi: "1.0.0"}
}
```

`build` est la version produit, celle du RPM. `abi` est le numéro de contrat
interne, figé.

Chaque page déclare `Requires: kelescope-core >= <version minimale>` et
`Requires: kelescope-runtime >= <version minimale>`. Ces bornes sont tenues à la
main dans `rpm/kelescope.spec` : elles sont relevées quand une page commence à
employer une nouveauté du socle. Un socle plus récent qu'une page est toujours
accepté.

Retirer une page laisse les autres en service :

```
dnf remove kelescope-mcu
```

Désinstallation complète :

```
dnf remove kelescope kelescope-core kelescope-monitor kelescope-domaines \
    kelescope-mcu kelescope-runtime
```

La désinstallation arrête et désactive le service, mais laisse en place
`/etc/kelescope/` (fichiers de configuration) et le compte système
`kelixip`.
