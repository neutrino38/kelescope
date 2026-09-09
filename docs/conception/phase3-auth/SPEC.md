# Phase 3 — Authentification : passkey, certificat client, rôles

Décision d'architecture : [ADR-004](../../architecture/adr-004-authentification-passkey-certificat.md).

Guide pour la personne qui s'enrôle : [docs/utilisation/enrolement.md](../../utilisation/enrolement.md).

## Objectif

Seul un administrateur enrôlé accède à kelescope. Il prouve deux choses à
chaque ouverture de session. Son poste, par un certificat client présenté dans
la poignée de main TLS. Sa personne, par une passkey WebAuthn.

Un rôle lui donne des droits en lecture ou en action. Ces droits portent sur
toute l'instance, ou sur une liste de domaines. Un administrateur général crée
les comptes, invite, réinitialise et révoque.

Le nom envoyé à kelixip lors d'une action destructrice est l'identifiant du
compte connecté. Le champ « Administrateur » de la popup de confirmation
disparaît. La confirmation reste.

Une seule instance kelescope, une seule instance kelixip, comme dans les phases
précédentes.

## Vocabulaire

- **Passkey** : identifiant WebAuthn (FIDO2). Il vit dans une clé de sécurité,
  un téléphone ou le gestionnaire du système (Windows Hello, Touch ID). Le
  navigateur signe un défi avec la clé privée. kelescope vérifie avec la clé
  publique enregistrée. La vérification de l'utilisateur, par code ou
  biométrie, est exigée.
- **Certificat client** : certificat X.509 émis par kelescope. Il s'importe
  dans le navigateur sous forme de fichier PKCS#12 protégé par mot de passe.
  Le navigateur le présente pendant la poignée de main TLS (mTLS).
- **Empreinte** : SHA-256 du certificat encodé en DER, en hexadécimal
  minuscule. C'est elle qui identifie un poste, pas l'émetteur.
- **Portée** : `all`, toute l'instance, ou une liste de noms de domaines
  kelixip.
- **Niveau** : `monitor`, lecture, ou `admin`, lecture et actions.

## Modèle

### Compte

| Champ | Contenu |
|---|---|
| `id` | Identifiant court, unique, `[a-z0-9._-]{2,32}`. C'est le nom tracé par kelixip. |
| `level` | `:monitor` ou `:admin`. |
| `scope` | `:all` ou liste de domaines. |
| `enabled` | Booléen. Un compte désactivé garde ses passkeys et ses certificats, mais aucune session ne s'ouvre. |
| `passkeys` | Liste : identifiant de credential, clé publique COSE, compteur de signature, AAGUID, libellé, date de création. |
| `certificates` | Liste : empreinte, numéro de série, libellé du poste, date d'émission, date d'expiration, date de révocation ou `nil`. |
| `invitation` | Code haché, date d'expiration, ou `nil`. |
| `last_login_at` | Horodatage de la dernière session ouverte, ou `nil`. |
| `created_at`, `updated_at` | Horodatages UTC. |

### Rôles

| | monitor / domaines | monitor / all | admin / domaines | admin / all |
|---|---|---|---|---|
| Voir les scénarios, domaines, enregistrements, conférences | de ses domaines | tous | de ses domaines | tous |
| Voir le pool de mediaservers et l'état de la connexion DB | non | oui | non | oui |
| Arrêter un scénario, désenregistrer un contact, recharger les scripts | non | non | ses domaines | tous |
| Créer, modifier, détruire une conférence, démarrer ou arrêter un enregistrement | non | non | ses domaines | tous |
| Gérer ses propres passkeys et postes (`/account`) | oui | oui | oui | oui |
| Gérer les comptes (`/admins`) | non | non | non | oui |

Un scénario appartient au domaine de sa colonne `domain`. Une conférence
appartient à son champ `domain`. Un enregistrement appartient à son domaine.

### Session

Le cookie de session signé, déjà en place, porte trois valeurs : `admin_id`,
`cert_fp`, l'empreinte du certificat au moment de la connexion, et
`authenticated_at`. La session expire après `KELESCOPE_SESSION_HOURS`, 12 par
défaut.

kelescope vérifie à chaque requête et à chaque montage LiveView que le
certificat présenté a la même empreinte que `cert_fp`, que cette empreinte est
toujours enregistrée et non révoquée, et que le compte est actif. Un cookie
volé sans le certificat ne sert à rien.

## Parcours

### Amorçage

Le service tourne, aucun compte n'existe. Sur l'hôte :

```
/opt/kelescope/bin/kelescope rpc 'Kelescope.Auth.bootstrap("prenom.nom")'
```

La commande crée un compte `admin / all` et affiche un code d'invitation. Elle
passe par `rpc` et non par `eval` : le nœud en marche est le seul à écrire le
fichier des comptes.

`bootstrap/2` refuse dès qu'un compte existe. Un administrateur général passe
alors par `/admins`.

La même commande rétablit l'accès quand tous les administrateurs généraux ont
perdu leurs moyens d'accès. `Kelescope.Auth.bootstrap("prenom.nom", force: true)`
crée un compte général de plus, sans toucher aux autres.

### Invitation

Sur `/admins`, un administrateur général crée un compte : identifiant, niveau,
portée. kelescope génère un code d'invitation de 20 caractères en base32,
l'affiche une fois, en stocke le SHA-256, et le fait expirer après
`KELESCOPE_INVITE_HOURS`, 24 par défaut. L'administrateur général transmet ce
code par le canal de son choix.

Le bouton « Réinitialiser » d'un compte existant génère un nouveau code. Il
sert quand la personne a perdu sa passkey ou son poste. Le code précédent
devient inutilisable.

### Enrôlement (`/enroll`)

Cette page est la seule atteignable sans certificat. La personne saisit son
identifiant et son code. Puis :

1. **Passkey.** Cérémonie d'enregistrement WebAuthn : `userVerification:
   required`, `residentKey: preferred`. L'identifiant de partie liée est
   `PHX_HOST`. kelescope accepte l'attestation au format `none` et enregistre
   la passkey avec un libellé saisi par la personne. Un compte qui a déjà une
   passkey peut passer cette étape.
2. **Certificat.** kelescope génère une clé EC P-256 et un certificat client
   signé par son autorité, valide `KELESCOPE_CLIENT_CERT_DAYS`, 365 par défaut,
   sujet `CN=<id>`, avec un libellé de poste saisi par la personne. Il construit
   un fichier PKCS#12 protégé par un mot de passe aléatoire de 16 caractères,
   affiche le mot de passe une fois, et pousse le fichier au navigateur. La clé
   privée n'est jamais écrite sur disque côté kelescope. L'empreinte est
   enregistrée dans le compte.
3. Le code d'invitation est consommé. La page explique comment importer le
   fichier. Elle demande de **fermer complètement le navigateur** avant de
   revenir : un navigateur réutilise une connexion TLS ouverte sans certificat,
   et ne présente pas le nouveau certificat tant qu'elle vit.

La vérification du code et sa consommation sont deux opérations distinctes.
`redeem_invitation/3` vérifie sans consommer, car le code doit rester valide
entre l'étape passkey et l'étape certificat. `consume_invitation/2` le retire à
la fin.

### Connexion (`/login`)

Toute route hors `/enroll`, `/login` et les fichiers statiques passe par le
plug d'authentification. Selon le certificat présenté :

- Aucun certificat : page « Poste non enrôlé », lien vers `/enroll`.
- Empreinte inconnue, révoquée, certificat expiré ou compte désactivé : page
  « Poste refusé ». L'identifiant du poste n'est pas affiché.
- Empreinte connue, compte actif, aucune passkey : page « Aucune passkey
  enregistrée », lien vers `/enroll`.
- Empreinte connue, compte actif, pas de session valide : cérémonie
  d'authentification WebAuthn. Les `allowCredentials` sont les passkeys du
  compte propriétaire du certificat. Aucun identifiant à saisir : le certificat
  a déjà désigné le compte. Le compteur de signature est vérifié et mis à jour.
- Session valide : accès.

Un LiveView ne peut pas écrire le cookie de session. `LoginLive` vérifie la
cérémonie, puis rend un formulaire vers `POST /session` portant un jeton signé
par `Phoenix.Token`, valable 60 secondes. `SessionController` vérifie le jeton,
vérifie que le certificat de cette requête est bien celui du jeton, écrit la
session et redirige vers la page demandée.

`DELETE /session`, le bouton « Déconnexion », vide la session. Le certificat
reste dans le navigateur. Une nouvelle session exigera la passkey.

`/login` affiche un avertissement quand l'hôte appelé diffère de `PHX_HOST` :
la cérémonie WebAuthn échouerait sans message clair.

### Mon compte (`/account`)

Tout administrateur connecté y voit ses passkeys et ses postes, avec leur
libellé, leur date d'émission et leur expiration. Il peut :

- ajouter une passkey, par la même cérémonie qu'à l'enrôlement ;
- ajouter un poste, c'est-à-dire télécharger un nouveau PKCS#12 pour un autre
  navigateur ;
- révoquer une passkey ou un poste, sauf le dernier de chaque sorte, et sauf le
  poste courant.

Ces actions n'ont pas besoin d'un administrateur général : la personne est déjà
authentifiée par ses deux facteurs.

### Gestion des comptes (`/admins`)

Cette page est réservée à `admin / all`. Elle liste les comptes avec leur
niveau, leur portée, leur état, leur nombre de passkeys et de postes actifs, et
leur dernière connexion.

Actions : créer, changer niveau et portée, désactiver et réactiver,
réinitialiser, révoquer une passkey ou un poste, supprimer.

Personne ne supprime son propre compte. Le bouton « Supprimer » n'apparaît pas
sur sa propre ligne. Le `handle_event` refuse en plus l'identifiant du compte
connecté : un navigateur choisit l'identifiant qu'il envoie.

Il reste toujours au moins un administrateur général actif. Cet invariant, tenu
par `Kelescope.Auth`, refuse la suppression, la désactivation et le
déclassement du dernier, quel que soit le demandeur.

La liste se recharge après chaque action de la page. Elle ne suit pas en direct
les changements faits par une autre session : le hook d'authentification est
seul abonné au topic des comptes, et il consomme ces messages.

## Mode dev

Hors production, kelescope démarre par défaut sans authentification. Le plug et
le hook assignent un compte synthétique `dev`, `admin / all`, sans certificat ni
passkey. `/login`, `/enroll` et `/account` répondent par une redirection vers
`/`. `/admins` reste accessible, pour développer la page sur le magasin de dev.
Un bandeau « Mode dev : authentification désactivée » s'affiche en tête de
page.

Activation : `config :kelescope_core, :auth_dev_mode, true`, posé dans
`runtime.exs` **uniquement** sous `config_env() != :prod`. La branche `:prod` ne
pose jamais cette clé, et sa valeur par défaut est `false`. Une release de
production ne peut donc pas démarrer sans authentification.

Pour travailler sur l'authentification réelle en dev :

```
mix phx.gen.cert                              # une fois
mix run -e 'Kelescope.Auth.bootstrap("dev")'  # service arrêté
KELESCOPE_AUTH_REAL=1 mix phx.server
```

Le mode dev est alors coupé. L'endpoint sert en HTTPS sur 4001 et exige un
certificat client. Le magasin vit dans `tmp/auth_dev/`.

Depuis une autre machine, `PHX_HOST` doit nommer le serveur, et le certificat
servi doit couvrir ce nom. `KELESCOPE_SSL_CERTFILE`, `KELESCOPE_SSL_KEYFILE` et
`KELESCOPE_HTTPS_PORT` remplacent les valeurs par défaut, qui ne conviennent
qu'à `localhost`.

L'environnement `:test` tourne avec l'authentification **réelle**, pour que les
tests des pages existantes prouvent aussi le filtrage par rôle.

## Stockage

Répertoire `KELESCOPE_AUTH_DIR`, `/var/lib/kelescope/auth` par défaut, créé au
premier démarrage avec le mode 0700. `StateDirectory=kelescope` du service
systemd garantit le répertoire parent.

| Fichier | Contenu | Mode |
|---|---|---|
| `admins.json` | Tous les comptes, un document JSON. | 0600 |
| `ca.key` | Clé privée EC P-256 de l'autorité, PEM. | 0600 |
| `ca.crt` | Certificat de l'autorité, PEM, valide 10 ans, `CN=kelescope CA <PHX_HOST>`. | 0644 |

`Kelescope.Auth.Store` est un GenServer. Il est le seul écrivain. Il charge le
fichier au démarrage dans son état, sert les lectures depuis une table ETS, et
écrit chaque changement dans `admins.json.tmp` puis `File.rename/2`, après
`:file.sync`.

Les écritures passent par `Store.update/2`. Cette fonction exécute une fonction
de transformation **dans le processus écrivain**. Un invariant vérifié dans
cette fonction tient donc encore quand le fichier est écrit.

La table ETS n'est jamais vidée avant d'être remplie. L'insertion de la liste
complète est atomique, et les entrées devenues inutiles partent après. Un
lecteur qui tombe pendant une écriture voit l'ancien état ou le nouveau, jamais
un magasin vide. Chaque connexion écrit, donc cette fenêtre n'est pas
théorique : sans cette précaution, le plug renverrait une session valide vers
`/login`.

Le fichier absent au démarrage donne un magasin vide, pas une erreur. Un
fichier illisible fait échouer le démarrage du superviseur du socle, avec le
chemin dans le journal : mieux vaut un service arrêté qu'un service ouvert à
tous.

Le magasin crée aussi l'autorité à son démarrage, si `ca.key` manque. Il le
fait avant l'endpoint, car les options TLS de l'endpoint pointent sur `ca.crt`
et une installation neuve n'en a pas. Sans cet ordre, le service ne démarre
pas, et l'amorçage par `rpc` devient impossible.

Sauvegarder le répertoire entier suffit à restaurer les accès. Aucun secret de
passkey ni de certificat client n'y figure : seulement des clés publiques, des
empreintes et des hachages de codes d'invitation.

## Configuration TLS

L'endpoint reçoit ces options, en `:prod` comme en dev réel :

```elixir
https: [
  # ... certfile, keyfile, port ...
  thousand_island_options: [
    transport_options: [
      verify: :verify_peer,
      fail_if_no_peer_cert: false,
      certificate_authorities: false,
      cacertfile: Path.join(auth_dir, "ca.crt"),
      verify_fun: {&Kelescope.Auth.ClientCert.verify_fun/3, nil}
    ]
  ]
]
```

Trois points comptent, et chacun a une raison précise.

**Bandit n'accepte que ses propres clés au premier niveau.** Toute autre option
TLS va dans `thousand_island_options.transport_options`. Posée à plat, elle
fait échouer le démarrage avec `Unsupported key(s) in top level config`.

**`fail_if_no_peer_cert: false`** laisse passer une connexion sans certificat.
C'est nécessaire pour `/enroll`.

**`certificate_authorities: false`** supprime l'extension TLS 1.3 du même nom.
OTP l'ajoute d'office dès qu'un serveur combine `verify_peer` et `cacertfile`.
Les navigateurs ne la digèrent pas : ils coupent la poignée de main avec
`decode_error`, avant toute requête, et le service est injoignable. `curl` et
OpenSSL l'acceptent, donc un test en ligne de commande ne révèle rien. Le prix
de sa suppression : l'invite de sélection du navigateur liste tous les
certificats clients du poste, et pas seulement ceux émis par kelescope.

La `verify_fun` accepte tout certificat présenté, quel que soit le verdict de
la chaîne. La décision appartient à la couche application, qui compare
l'empreinte au magasin. Deux raisons : un certificat révoqué ou expiré donne
une page explicative et non une alerte TLS illisible, et l'épinglage par
empreinte rend la vérification de chaîne redondante. `cacertfile` reste
renseigné pour peupler le magasin de certificats du serveur.

Le socket LiveView passe `connect_info: [:peer_data, session: ...]`. Bandit
remonte le certificat dans `Plug.Conn.get_peer_data/1`, clé `ssl_cert`, pour la
requête HTTP comme pour le WebSocket.

Le rendu statique d'un LiveView se produit avant que la socket existe : il n'a
donc pas accès à `:peer_data`. Chaque `live_session` reçoit pour cela
`session: {KelescopeWeb.AuthHook, :peer_session, []}`, qui glisse l'empreinte et
l'hôte de la requête dans les données de session du montage. Le montage
connecté, lui, relit toujours le certificat réel de la socket.

## Composants livrés

### `kelescope_core` (socle, paquet `kelescope-core`)

- `Kelescope.Auth` : les fonctions métier. `bootstrap/2`, `create_account/2`,
  `invite/2`, `redeem_invitation/3`, `consume_invitation/2`, `add_passkey/3`,
  `update_sign_count/4`, `revoke_passkey/3`, `issue_certificate/3`,
  `revoke_certificate/3`, `authenticate_certificate/2`, `update_role/3`,
  `set_enabled/3`, `delete_account/2`, `touch_login/2`, `resolve/3`,
  `session_payload/2`, `dev_mode?/0`. Toutes valident les invariants du dernier
  administrateur général. Toutes acceptent une option `store:`, qui nomme un
  magasin autre que celui de l'application ; les tests d'invariants globaux
  s'en servent pour tourner isolés.
- `Kelescope.Auth.Store` : le GenServer et le fichier JSON, décrits plus haut.
- `Kelescope.Auth.CA` : création de l'autorité, émission d'un certificat client
  avec la bibliothèque `x509`, construction du PKCS#12. Ni OTP ni `x509` ne
  savent encoder du PKCS#12 : `openssl` s'en charge. Il lit chaque PEM une fois,
  sur un flux qu'il ne sait pas rembobiner, donc le certificat, la clé et
  l'autorité ont chacun leur descripteur. Le tout passe par l'environnement d'un
  `bash`, jamais par un fichier.
- `Kelescope.Auth.Passkey` : enveloppe de `Wax`. Défis d'enregistrement et
  d'authentification, options poussées au navigateur, vérification. L'origine et
  l'identifiant de partie liée viennent de la configuration `url` de l'endpoint.
- `Kelescope.Auth.Scope` : struct `%Scope{admin: %{id, level, domains},
  certificate, dev?}` et prédicats `can?/3`, `sees_domain?/2`, `global?/1`,
  `visible_domains/2`, `id/1`. Assignée sous `current_scope`.
- `Kelescope.Auth.ClientCert` : `verify_fun/3`, et extraction de l'empreinte
  depuis `get_peer_data/1`.
- `KelescopeWeb.Plugs.Auth` : lit le certificat, la session et le mode dev, puis
  assigne `current_scope` ou redirige. Option `require:` avec `:none`,
  `:authenticated` ou `:manage_accounts`. L'authentification ne s'exécute qu'une
  fois par requête, même quand plusieurs pipelines la demandent.
- `KelescopeWeb.AuthHook` : l'équivalent `on_mount`, mêmes options, placé dans
  les `live_session` avant `LocaleHook`. Il s'abonne au topic `"auth:accounts"`.
  Une révocation ou une désactivation coupe la session LiveView en cours, sans
  attendre le prochain montage.
- `KelescopeWeb.EnrollLive` (`/enroll`), `KelescopeWeb.LoginLive` (`/login`),
  `KelescopeWeb.SessionController` (`POST /session`, `DELETE /session`). Ces
  deux pages n'affichent pas la barre de navigation. Elles appellent donc
  `CoreComponents.locale_switch/1` et `CoreComponents.font_size/1`
  elles-mêmes, sinon un poste refusé n'aurait aucun moyen de lire son refus
  ([docs/reference/langues.md](../../reference/langues.md)).
- Hook JavaScript `Passkey` (`assets/js/passkey.js`) : il appelle
  `navigator.credentials.create` ou `.get` avec les options poussées par le
  LiveView, encode les tampons en base64url, et renvoie le résultat par
  `pushEvent`. Il signale l'absence de support WebAuthn. Le même fichier porte
  `AutoSubmit`, qui soumet le formulaire de reprise de session, et le
  téléchargement du PKCS#12, qu'un LiveView ne sait pas déclencher seul.
- `CoreComponents.nav/1` : identifiant et rôle du compte, liens vers `/account`,
  vers `/admins` pour un administrateur général, bouton « Déconnexion », bandeau
  du mode dev, sélecteur de langue et taille du texte. Les pages appellent ce
  composant ; `Layouts.app/1` n'est pas utilisé dans ce dépôt.
- `CoreComponents.admin_confirm_modal/1` : le champ « Administrateur » est
  retiré. L'événement de confirmation resoumet les `confirm_values` seuls. Les
  appelants prennent l'identifiant dans `current_scope`.
- Routeur : le pipeline `:browser` se termine par `KelescopeWeb.Plugs.Auth,
  require: :none`, qui assigne sans décider. Deux pipelines s'ajoutent ensuite,
  `:authenticated` et `:global_admin`. Un `live_session :public` porte `/enroll`
  et `/login`, un `live_session :authenticated` les pages existantes et
  `/account`, un `live_session :global_admin` la page `/admins`.

### Pages existantes

Le filtrage se fait **avant l'assign**, jamais dans le gabarit. Un scénario, un
domaine ou une conférence hors portée n'atteint pas la socket, donc aucune
poussée en direct ne peut le laisser fuir.

- `ScenarioMonitorLive` (`kelescope_monitor`) : filtre les scénarios au montage
  et à chaque `handle_info`. Le `<select>` de la phase 2 ne propose que les
  domaines visibles. Le panneau d'état de l'instance, pool de mediaservers et
  connexion DB, n'apparaît que pour une portée `all`. Le bouton « Arrêter »
  n'apparaît que si `can?(scope, :shutdown, domain)`.
- `DomainListLive` (`kelescope_domaines`) : même filtrage sur la liste et sur
  les poussées de compteurs. « Recharger » et « Désenregistrer » sont soumis à
  `can?/3`.
- `McuLive` (`kelescope_mcu`) : conférences filtrées par domaine. Création,
  modification, destruction et enregistrement soumis à `can?/3`. La liste
  déroulante des domaines du formulaire de création ne propose que la portée.
- Chaque `handle_event` d'action revérifie le droit. Un bouton masqué n'est pas
  une protection : le navigateur choisit l'identifiant qu'il envoie.

### `kelescope_admins` (nouvelle partie, paquet `kelescope-admins`)

`KelescopeWeb.AdminsLive` (`/admins`) et `KelescopeWeb.AccountLive`
(`/account`), avec leur backend Gettext (ADR-003). Les routes vivent dans le
socle (ADR-002).

### `kelescope-runtime`

- Dépendances : `wax_ ~> 0.7` et `x509 ~> 0.9`. Elles sont déclarées dans
  `kelescope_core`, qui les utilise, et dans `kelescope_boot`, dont la charge
  utile forme le paquet.
- `runtime.exs` : les options TLS ci-dessus, les variables ci-dessous, et le
  mode dev hors `:prod`.
- Spec RPM : `Requires: openssl`, la commande et pas seulement `openssl-libs`.
  En `%post`, si `admins.json` est absent, la commande d'amorçage s'affiche.
- `rpm/kelescope.env` : les nouvelles variables, commentées.

### Variables d'environnement

| Variable | Rôle | Défaut |
|---|---|---|
| `KELESCOPE_AUTH_DIR` | Répertoire des comptes et de l'autorité. | `/var/lib/kelescope/auth` |
| `KELESCOPE_CLIENT_CERT_DAYS` | Validité d'un certificat client, en jours. | `365` |
| `KELESCOPE_SESSION_HOURS` | Durée d'une session. | `12` |
| `KELESCOPE_INVITE_HOURS` | Validité d'un code d'invitation. | `24` |

`PHX_HOST` existe déjà. Il devient l'identifiant de partie liée WebAuthn : le
navigateur doit appeler kelescope exactement par ce nom. Une adresse IP ou un
autre alias fait échouer toute cérémonie WebAuthn.

### Côté elixip

Rien. kelixip reçoit déjà un nom d'administrateur sur les actions tracées. Il
reçoit désormais un identifiant vérifié.

### Documentation

- `docs/maintenance/paquet-rpm.md` : les nouvelles variables, l'amorçage, la
  sauvegarde de `KELESCOPE_AUTH_DIR`, la procédure de perte totale d'accès.
- `docs/utilisation/enrolement.md` : l'import du PKCS#12 dans Firefox, Chrome et
  le magasin système, le redémarrage du navigateur, la gestion des passkeys.
- `README.md` : le titre et le contenu de la phase 3, et la marche à suivre pour
  développer avec l'authentification réelle.

## Tests

`Kelescope.AuthCase` donne à chaque test son propre magasin, dans son propre
répertoire. Les tests qui touchent aux invariants du dernier administrateur
général ne se voient donc pas les uns les autres.

`KelescopeWeb.ConnCase` fournit `admin_fixture/2`, `log_in/2` et
`log_in_admin/3`. Le premier crée un compte, sa passkey et son certificat. Les
autres posent le certificat sur la connexion avec `Plug.Test.put_peer_data/2` et
ouvrent la session. `Phoenix.LiveViewTest` réutilise la connexion comme
`connect_info` de la socket, donc la même donnée sert à la requête et au
montage.

`Kelescope.WebAuthnAuthenticator` est un authentificateur logiciel. Il signe
réellement en ES256 et répond aux deux cérémonies comme le ferait une clé de
sécurité. La bibliothèque `wax_` ne livre pas ses vecteurs de test dans son
paquet hex, et un double qui ne signe pas ne prouverait rien.

Ce que chaque fichier établit :

- `Kelescope.AuthTest` : amorçage refusé si des comptes existent ; invitation
  consommée une seule fois et expirée après le délai ; dernier administrateur
  général indésactivable, insupprimable et indéclassable ; révocation de la
  dernière passkey et du dernier poste refusée ; compteur de signature
  régressif refusé ; `authenticate_certificate/2` distingue inconnu, révoqué,
  expiré, compte désactivé, valide.
- `Kelescope.Auth.StoreTest` : rechargement après écriture, écriture atomique,
  fichier temporaire jamais lu, fichier absent, fichier corrompu, index des
  empreintes.
- `Kelescope.Auth.CATest` : création de l'autorité et modes des fichiers,
  émission, empreinte stable après un aller-retour DER, PKCS#12 relu par
  `openssl pkcs12 -info` avec le mot de passe et refusé sans.
- `Kelescope.Auth.PasskeyTest` : enregistrement et authentification complets ;
  défi d'un autre échange refusé ; signature d'un autre authentificateur
  refusée ; credential non autorisé refusé.
- `KelescopeWeb.Plugs.AuthTest` : sans certificat, certificat inconnu, révoqué,
  session sans certificat, empreinte de session différente du certificat
  présenté, session expirée, compte désactivé pendant la session, page réservée
  à l'administrateur général. Un cas parcourt toutes les routes GET du routeur
  et vérifie qu'aucune ne répond sans les deux facteurs.
- `KelescopeWeb.AuthHookTest` : les mêmes refus au montage LiveView, et la
  coupure d'une session ouverte sur révocation, désactivation ou suppression.
- `KelescopeWeb.LoginLiveTest`, `EnrollLiveTest` : les parcours complets, du
  premier écran jusqu'à la session ouverte, avec l'authentificateur logiciel ;
  jeton de reprise inutilisable depuis un autre poste ; déconnexion.
- `KelescopeWeb.AdminsLiveTest`, `AccountLiveTest` : chaque action, chaque
  refus.
- Tests des trois pages existantes : un cas `monitor / domaines` vérifie que les
  lignes des autres domaines sont absentes du rendu **et** des poussées, et
  qu'aucun bouton d'action n'apparaît. Un cas `admin / domaines` vérifie que le
  `handle_event` refuse une action sur un domaine hors portée, même avec un
  événement forgé. Un cas vérifie qu'un changement de compte ailleurs ne fait
  pas tomber la page.

Les tests qui basculent `:auth_dev_mode` vivent dans leurs propres modules, en
`async: false` : cette clé est globale à l'application, et un test asynchrone
qui la modifie enverrait tous les autres sur le chemin du mode dev.

### Test manuel

Un test manuel dans Firefox et Chrome reste obligatoire avant livraison :
enrôlement complet, redémarrage du navigateur, connexion, révocation du poste
depuis un autre poste, déconnexion. L'authentificateur virtuel des outils de
développement de Chrome suffit pour la passkey.

## Critères d'acceptation

- Sans certificat client, aucune page autre que `/enroll`, `/login` et les
  fichiers statiques ne renvoie autre chose qu'une page de refus.
- Avec un certificat connu mais sans passkey, aucune session ne s'ouvre.
- Un compte `monitor / domaines` ne reçoit dans le DOM aucune donnée d'un autre
  domaine, y compris après une poussée en direct.
- Un compte `admin / domaines` ne peut pas déclencher une action sur un domaine
  hors portée, même en forgeant l'événement LiveView.
- La révocation d'un poste ou la désactivation d'un compte coupe les sessions
  LiveView ouvertes en moins de cinq secondes.
- Aucune page ne tombe quand un compte change, quel qu'il soit.
- Le nom tracé par kelixip est l'identifiant du compte connecté, jamais une
  saisie.
- Une release `:prod` ne peut pas démarrer en mode dev.
- `KELESCOPE_AUTH_DIR` restauré depuis une sauvegarde redonne tous les accès.

## Hors périmètre

- Enregistrer un certificat émis par une autre autorité, par exemple une PKI
  d'entreprise. L'épinglage par empreinte le permet sans changer le modèle, à
  traiter quand le besoin existe.
- OAuth et OpenID Connect.
- Plusieurs nœuds kelescope partageant un magasin de comptes.
- Journal d'audit dans kelescope. Seul kelixip trace, comme en phase 2.
- Liste de révocation ou OCSP pour les certificats clients.
- Droits plus fins qu'un niveau et une portée.
- Rafraîchissement en direct de la liste de `/admins` sur le changement d'une
  autre session.

## Pièges et risques

- **Connexion TLS réutilisée après enrôlement.** Le navigateur garde la
  connexion ouverte sans certificat, et ne présente pas le nouveau certificat
  tant qu'elle vit. La page d'enrôlement demande de fermer le navigateur. C'est
  le piège le plus fréquent à prévoir en support.
- **Invite de sélection de certificat.** Elle liste tous les certificats clients
  du poste, puisque l'extension `certificate_authorities` est désactivée. Chaque
  navigateur l'affiche à sa façon, parfois sur chaque nouvelle connexion.
- **`PHX_HOST` et l'identifiant de partie liée.** Un accès par adresse IP ou par
  alias DNS casse WebAuthn avec un message peu clair. C'est documenté dans
  `paquet-rpm.md`, et `/login` l'affiche quand l'hôte de la requête diffère.
- **Format du PKCS#12.** OpenSSL 3 chiffre en AES-256 avec PBKDF2 par défaut.
  Certains importeurs anciens exigent `-legacy`, c'est-à-dire RC2 ou 3DES.
  L'option affaiblit la protection du fichier et ne doit pas devenir le défaut.
- **`verify_fun` permissive.** La couche TLS ne protège plus rien. Toute la
  protection tient au plug et au hook. Une route ajoutée hors des `live_session`
  protégées serait publique. Un test parcourt la liste des routes du routeur
  pour l'empêcher.
- **Messages du topic des comptes.** Le hook est seul abonné, et il consomme ces
  messages. Les transmettre ferait tomber toutes les pages ouvertes : elles
  n'ont aucune clause `handle_info` qui leur corresponde, et une simple
  connexion d'administrateur suffirait à les faire planter.
- **Perte de passkey ou de poste.** Un administrateur général réinitialise le
  compte. La perte de tous les administrateurs généraux se rattrape par
  `bootstrap/2` sur l'hôte, ce qui suppose l'accès shell : c'est la racine de
  confiance, à protéger comme telle.
- **Fichiers statiques publics.** `Plug.Static` sert le logo, le CSS et le
  JavaScript avant le routeur, donc sans authentification. Rien de sensible n'y
  figure, à garder en tête pour tout ajout futur dans `priv/static`.
- **`wax_`** : un seul mainteneur, mais une bibliothèque active et largement
  téléchargée. Alternative écartée : `webauthn_components`, qui exige Ecto et
  LiveView 0.20.
- **Le cookie Erlang** reste un accès total au nœud kelixip (ADR-001). Cette
  phase n'y change rien.
