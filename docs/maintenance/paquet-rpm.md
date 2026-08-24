# Paquet RPM

Le paquet `kelescope` installe une release Elixir autonome dans
`/opt/kelescope` et un service systemd `kelescope.service` qui l'expose en
HTTPS sur le port 8443. La release embarque son propre runtime Erlang : la
machine cible n'a besoin ni d'Elixir ni d'Erlang installés, seulement des
bibliothèques système habituelles (OpenSSL, ncurses), déjà présentes sur une
installation RHEL/AlmaLinux standard.

Fichiers du paquet : `rpm/kelescope.spec`, `rpm/kelescope.service`,
`rpm/kelescope.env`, `rpm/build.sh`.

## Construire le paquet

Prérequis sur la machine de build : `elixir` (≥ 1.17) dans le `PATH`,
`erlang` (≥ 26, paquet RPM), `rpmbuild`, et un accès réseau à hex.pm et
GitHub. Elixir n'existe pas comme paquet RPM pour EL9 : la version
installée est vérifiée au début de la section `%build` du spec (pas via
`BuildRequires`, que rpmbuild ne peut valider que contre la base RPM).

```
./rpm/build.sh
```

Le script archive l'arbre de travail courant (hors `.git`, `_build`,
`deps`), puis appelle `rpmbuild`. Le paquet est déplacé dans le
répertoire depuis lequel `build.sh` a été lancé, et l'arborescence de
build (`rpm/build/`) est supprimée.

L'étape de build télécharge les dépendances Elixir (hex.pm) et les
binaires autonomes de tailwind et esbuild (GitHub, npmjs.org) : c'est la
seule différence notable avec le packaging RPM d'une application non-web.
Un environnement de build isolé du réseau (mock, koji) ne peut pas
construire ce paquet tel quel ; il faut soit lui donner un accès réseau
pour ces trois domaines, soit pré-construire la release ailleurs
(`MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release`) et adapter
la section `%build` du spec pour réutiliser `_build/prod/rel/kelescope`
sans relancer ces commandes.

La version du paquet (champ `Version` du spec) suit celle de `mix.exs` et
doit être mise à jour à la main lors d'un changement de version.

## Installer

```
dnf install ./kelescope-0.1.0-1.el9.x86_64.rpm
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
questions garde le chemin déjà présent dans `kelescope.env` (le défaut
`/etc/kelescope/tls/kelescope.{crt,key}` documenté ci-dessous). Sans
terminal interactif, ou si les chemins renseignés restent invalides,
l'installation affiche un rappel plutôt que d'échouer.

## Configurer

Toute la configuration passe par `/etc/kelescope/kelescope.env`, chargé
par systemd (`EnvironmentFile=`).

| Variable | Rôle |
|---|---|
| `PHX_HOST` | Nom d'hôte public, utilisé pour générer les URLs. |
| `SECRET_KEY_BASE` | Secret de signature des sessions. Au moins 64 caractères, sinon le service démarre mais renvoie une erreur 500 sur chaque requête. Générer avec `mix phx.gen.secret` ou `openssl rand -base64 48`, directement sur la machine cible (voir remarque sur le copier-coller ci-dessous). |
| `RELEASE_NODE` | Identité du nœud Erlang de kelescope (nom long, ex. `kelescope@host.example.org`). Nécessite `RELEASE_DISTRIBUTION=name`. |
| `RELEASE_DISTRIBUTION` | Mode de distribution Erlang. À positionner à `name` : une release Elixir démarre par défaut en noms courts (`sname`), incompatible avec un `RELEASE_NODE` en nom long ou en adresse IP. Sans cette variable, le service ne démarre pas (`net_kernel` échoue avec `nodistribution`). |
| `RELEASE_COOKIE` | Cookie Erlang du nœud kelescope lui-même. Laissé vide, `mix release` en a déjà fixé un par défaut à la construction ; à ne renseigner que si plusieurs nœuds kelescope doivent partager une identité. |
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

Le service écrit ses journaux sur la sortie standard, capturée par
journald : aucune rotation de fichier de log à gérer.

Symptômes fréquents dans `journalctl -u kelescope` :

| Message | Cause |
|---|---|
| `failed_to_start_child,net_kernel,{'EXIT',nodistribution}` | `RELEASE_DISTRIBUTION=name` absent, voir la table des variables. |
| `Runtime terminating during boot` (sans autre détail) | Le plus souvent `KELESCOPE_SSL_CERTFILE`/`KELESCOPE_SSL_KEYFILE` illisible par `kelixip`, voir la section certificats. |
| `cookie store expects conn.secret_key_base to be at least 64 bytes` | `SECRET_KEY_BASE` fait moins de 64 caractères (souvent un caractère perdu au copier-coller). |
| `kelixip link to <nœud>: :connect_failed` | À corréler avec `journalctl -u kelixip` sur l'autre hôte. `Invalid challenge reply` : `KELIXIP_COOKIE` ne correspond pas au cookie du nœud kelixip. Pas de message de rejet côté kelixip : vérifier le réseau (EPMD 4369/tcp et port de distribution BEAM, voir ADR-001) et que `KELIXIP_NODE` correspond exactement au nom et à l'adresse du nœud kelixip (`ps -eo cmd | grep beam.smp` sur l'hôte kelixip donne son `-name` et son `-setcookie` réels). |

## Mettre à jour ou désinstaller

```
dnf upgrade ./kelescope-<version>-1.el9.x86_64.rpm
dnf remove kelescope
```

La désinstallation arrête et désactive le service, mais laisse en place
`/etc/kelescope/` (fichiers de configuration) et le compte système
`kelixip`.
