# Phase 3 — Authentification : passkey, certificat client, rôles

Décision d'architecture : [ADR-004](../../architecture/adr-004-authentification-passkey-certificat.md).

## Objectif

Seul un administrateur enrôlé accède à kelescope. Il prouve deux choses à
chaque ouverture de session : son poste, par un certificat client présenté
dans la poignée de main TLS, et sa personne, par une passkey WebAuthn. Un rôle
lui donne des droits en lecture ou en action, sur toute l'instance ou sur une
liste de domaines. Un administrateur global crée les comptes, invite, réinitialise
et révoque.

Le nom envoyé à kelixip lors d'une action destructrice est l'identifiant du
compte connecté. Le champ « Administrateur » de la popup de confirmation
disparaît ; la confirmation reste.

Une seule instance kelescope, une seule instance kelixip, comme dans les phases
précédentes.

## Vocabulaire

- **Passkey** : identifiant WebAuthn (FIDO2) stocké dans une clé de sécurité,
  un téléphone ou le gestionnaire du système (Windows Hello, Touch ID). Le
  navigateur signe un défi avec la clé privée ; kelescope vérifie avec la clé
  publique enregistrée. La vérification de l'utilisateur (code, biométrie) est
  exigée.
- **Certificat client** : certificat X.509 émis par kelescope, importé dans le
  navigateur sous forme de fichier PKCS#12 protégé par mot de passe. Le
  navigateur le présente pendant la poignée de main TLS (mTLS).
- **Empreinte** : SHA-256 du certificat encodé en DER. C'est elle qui identifie
  un poste, pas l'émetteur.
- **Portée** : `all` (toute l'instance) ou une liste de noms de domaines
  kelixip.
- **Niveau** : `monitor` (lecture) ou `admin` (lecture et actions).

## Modèle

### Compte

| Champ | Contenu |
|---|---|
| `id` | Identifiant court, unique, `[a-z0-9._-]{2,32}`. C'est le nom tracé par kelixip. |
| `level` | `monitor` ou `admin`. |
| `scope` | `all` ou liste de domaines. |
| `enabled` | Booléen. Un compte désactivé garde ses passkeys et certificats, mais aucune session ne s'ouvre. |
| `passkeys` | Liste : identifiant de credential, clé publique COSE, compteur de signature, AAGUID, libellé, date de création. |
| `certificates` | Liste : empreinte, numéro de série, libellé du poste, date d'émission, date d'expiration, date de révocation ou `null`. |
| `invitation` | Code haché, date d'expiration, ou `null`. |
| `created_at`, `updated_at` | Horodatages UTC. |

### Rôles

| | monitor / domaines | monitor / all | admin / domaines | admin / all |
|---|---|---|---|---|
| Voir les scénarios, domaines, enregistrements, conférences | de ses domaines | tous | de ses domaines | tous |
| Voir le pool de mediaservers, l'état de la connexion DB (README phase 2, à venir) | non | oui | non | oui |
| Arrêter un scénario, désenregistrer un contact, recharger les scripts | non | non | ses domaines | tous |
| Créer, modifier, détruire une conférence, démarrer ou arrêter un enregistrement | non | non | ses domaines | tous |
| Gérer ses propres passkeys et postes (`/account`) | oui | oui | oui | oui |
| Gérer les comptes (`/admins`) | non | non | non | oui |

Un scénario appartient au domaine de sa colonne `domain`. Une conférence
appartient à son champ `domain`. Un enregistrement appartient à son domaine.

### Session

Cookie de session signé, déjà en place. Il porte : `admin_id`, `cert_fp`
(empreinte du certificat au moment de la connexion), `authenticated_at`. La
session expire après `KELESCOPE_SESSION_HOURS` (12 par défaut). À chaque
requête et à chaque montage LiveView, kelescope vérifie que le certificat
présenté a la même empreinte que `cert_fp`, que cette empreinte est toujours
enregistrée et non révoquée, et que le compte est actif. Un cookie volé sans le
certificat ne sert à rien.

## Parcours

### Amorçage

Le service tourne, aucun compte n'existe. Sur l'hôte :

```
/opt/kelescope/bin/kelescope rpc 'Kelescope.Auth.bootstrap("prenom.nom")'
```

Crée un compte `admin / all` et affiche un code d'invitation. La commande passe
par `rpc` et non par `eval` : le nœud en marche est le seul à écrire le
fichier des comptes. Si des comptes existent déjà, `bootstrap/1` refuse ; un
administrateur global passe alors par `/admins`. La même commande sert à
rétablir l'accès quand tous les administrateurs globaux ont perdu leurs
moyens d'accès : `Kelescope.Auth.bootstrap("prenom.nom", force: true)` crée
un compte global de plus, sans toucher aux autres.

### Invitation

Sur `/admins`, un administrateur global crée un compte (identifiant, niveau,
portée). kelescope génère un code d'invitation de 20 caractères en base32,
l'affiche une fois, en stocke le SHA-256, et le fait expirer après
`KELESCOPE_INVITE_HOURS` (24 par défaut). L'administrateur global transmet ce
code par le canal de son choix. Le même bouton « Réinitialiser » sur un compte
existant génère un nouveau code : il sert quand la personne a perdu sa passkey
ou son poste.

### Enrôlement (`/enroll`)

Page atteignable sans certificat. La personne saisit son identifiant et son
code. Puis :

1. **Passkey.** Cérémonie d'enregistrement WebAuthn : `userVerification:
   required`, `residentKey: preferred`, l'identifiant de partie liée est
   `PHX_HOST`. kelescope vérifie l'attestation au format `none` et enregistre la
   passkey avec un libellé saisi par la personne. Cette étape est obligatoire si
   le compte n'a aucune passkey, facultative sinon.
2. **Certificat.** kelescope génère une clé EC P-256 et un certificat client
   signé par son autorité, valide `KELESCOPE_CLIENT_CERT_DAYS` (365 par
   défaut), sujet `CN=<id>`, libellé du poste saisi par la personne. Il
   construit un fichier PKCS#12 protégé par un mot de passe aléatoire de 16
   caractères, affiche le mot de passe une fois, propose le téléchargement.
   La clé privée n'est jamais écrite sur disque côté kelescope. L'empreinte
   est enregistrée dans le compte.
3. Le code d'invitation est consommé. La page explique comment importer le
   fichier, et demande de **fermer complètement le navigateur** avant de
   revenir : un navigateur réutilise une connexion TLS ouverte sans certificat
   et ne présente pas le nouveau certificat tant qu'elle vit.

### Connexion (`/login`)

Toute route hors `/enroll` et les fichiers statiques passe par le plug
d'authentification. Selon le certificat présenté :

- Aucun certificat : page « poste non enrôlé », lien vers `/enroll`.
- Empreinte inconnue, révoquée, ou certificat expiré : page « poste refusé »,
  identifiant du poste non affiché.
- Empreinte connue, compte actif, pas de session valide : cérémonie
  d'authentification WebAuthn avec, comme `allowCredentials`, les passkeys du
  compte propriétaire du certificat. Aucun identifiant à saisir : le certificat
  a déjà désigné le compte. Le compteur de signature est vérifié et mis à jour.
- Session valide : accès.

Un LiveView ne peut pas écrire le cookie de session. `LoginLive` vérifie la
cérémonie, puis redirige vers `POST /session` avec un jeton signé
(`Phoenix.Token`, 60 secondes) ; `SessionController` écrit la session et
redirige vers la page demandée. C'est le schéma habituel de `phx.gen.auth`
avec LiveView.

`DELETE /session` (bouton « Déconnexion ») vide la session. Le certificat
reste dans le navigateur : la page le dit, et rappelle qu'une nouvelle session
exigera la passkey.

### Mon compte (`/account`)

Tout administrateur connecté y voit ses passkeys et ses postes (libellé, date
d'émission, expiration), et peut :

- ajouter une passkey (cérémonie d'enregistrement, comme à l'enrôlement) ;
- ajouter un poste : télécharger un nouveau PKCS#12 pour un autre navigateur,
  comme à l'étape 2 de l'enrôlement ;
- révoquer une passkey ou un poste, sauf le dernier de chaque sorte, et sauf
  le poste courant.

Ces actions n'ont pas besoin d'un administrateur global : la personne est déjà
authentifiée par ses deux facteurs.

### Gestion des comptes (`/admins`)

Réservée à `admin / all`. Liste des comptes avec niveau, portée, état, nombre de
passkeys et de postes, dernière connexion. Actions : créer, changer niveau et
portée, désactiver et réactiver, réinitialiser (nouveau code d'invitation),
révoquer une passkey ou un poste, supprimer. Un administrateur global ne peut
ni se désactiver, ni se supprimer, ni se retirer le niveau global : il en
reste toujours au moins un.

## Mode dev

Hors production, kelescope démarre par défaut avec l'authentification
désactivée. Le plug et le hook assignent un compte synthétique `dev`,
`admin / all`, sans certificat ni passkey. `/login`, `/enroll`, `/account` et
`/session` répondent par une redirection vers `/`. `/admins` reste accessible
pour développer la page, sur le magasin de dev. Un bandeau « Mode dev :
authentification désactivée » s'affiche dans le layout, et un avertissement
est journalisé au démarrage.

Activation : `config :kelescope_core, :auth_dev_mode, true`, posé dans
`runtime.exs` **uniquement** sous `config_env() != :prod`, sur le modèle exact
de `:kelixip_stub`. La branche `:prod` de `runtime.exs` ne pose jamais cette
clé ; sa valeur par défaut est `false`. Une release de production ne peut donc
pas l'activer.

Pour travailler sur l'authentification réelle en dev :
`KELESCOPE_AUTH_REAL=1 mix phx.server`. Le mode dev est alors coupé, l'endpoint
sert en HTTPS sur 4001 avec le certificat de `mix phx.gen.cert`, et le magasin
vit dans `tmp/auth_dev/`. WebAuthn fonctionne sur `localhost` en contexte
sécurisé ; mTLS exige HTTPS. L'amorçage se fait avec
`mix run -e 'Kelescope.Auth.bootstrap("dev")'` sur le même magasin, service
arrêté.

L'environnement `:test` tourne avec l'authentification **réelle**, pour que
les tests des pages existantes prouvent aussi le filtrage par rôle.
`ConnCase` fournit `log_in_admin(conn, level, scope)` : crée un compte dans un
magasin temporaire propre au test, injecte un certificat de test par
`Plug.Test.put_peer_data/2`, et pose la session. Pour LiveView, le même
certificat passe par `Phoenix.LiveViewTest.put_connect_info/2`.

## Stockage

Répertoire `KELESCOPE_AUTH_DIR` (`/var/lib/kelescope/auth` par défaut, créé au
premier démarrage avec le mode 0700 ; `StateDirectory=kelescope` du service
systemd garantit le répertoire parent).

| Fichier | Contenu | Mode |
|---|---|---|
| `admins.json` | Tous les comptes, un document JSON. | 0600 |
| `ca.key` | Clé privée EC P-256 de l'autorité, PEM. | 0600 |
| `ca.crt` | Certificat de l'autorité, PEM, valide 10 ans, `CN=kelescope CA <PHX_HOST>`. | 0644 |

`Kelescope.Auth.Store` (GenServer) est le seul écrivain. Il charge le fichier
au démarrage dans son état, sert les lectures depuis une table ETS, et écrit
chaque changement dans `admins.json.tmp` puis `File.rename/2`, après
`:file.sync`. Le fichier absent au démarrage donne un magasin vide, pas une
erreur. Un fichier illisible (JSON invalide) fait échouer le démarrage du
superviseur du socle, avec le chemin dans le journal : mieux vaut un service
arrêté qu'un service ouvert à tous.

L'autorité est créée au premier démarrage si `ca.key` manque. Sauvegarder le
répertoire entier suffit à restaurer les accès.

Aucun secret de passkey ni de certificat client n'est stocké : seulement des
clés publiques, des empreintes et des hachages de codes d'invitation.

## Configuration TLS

Dans `runtime.exs`, branche `:prod`, l'endpoint gagne :

```
verify: :verify_peer,
fail_if_no_peer_cert: false,
cacertfile: Path.join(auth_dir, "ca.crt"),
verify_fun: {&Kelescope.Auth.ClientCert.verify_fun/3, nil}
```

`fail_if_no_peer_cert: false` laisse passer une connexion sans certificat :
c'est nécessaire pour `/enroll`. La `verify_fun` accepte tout certificat
présenté, quel que soit le verdict de la chaîne. La décision appartient à la
couche application, qui compare l'empreinte au magasin. Deux raisons : un
certificat révoqué ou expiré donne une page explicative et non une alerte TLS
illisible, et l'épinglage par empreinte rend la vérification de chaîne
redondante. `cacertfile` reste renseigné pour que le navigateur limite son
choix aux certificats émis par kelescope ; le détail de cette sélection varie
selon les navigateurs, à valider lors de l'implémentation.

Le socket LiveView passe `connect_info: [:peer_data, session: ...]`. Bandit
remonte le certificat dans `Plug.Conn.get_peer_data/1` (`ssl_cert`), pour la
requête HTTP comme pour le WebSocket.

## Composants à livrer

### `kelescope_core` (socle, paquet `kelescope-core`)

- `Kelescope.Auth` : fonctions métier. `bootstrap/2`, `create_account/1`,
  `invite/1`, `redeem_invitation/2`, `add_passkey/2`, `issue_certificate/2`,
  `revoke_passkey/2`, `revoke_certificate/2`, `authenticate_certificate/1`
  (empreinte → compte ou raison de refus), `update_role/2`, `set_enabled/2`,
  `delete_account/1`. Toutes valident les invariants du dernier
  administrateur global.
- `Kelescope.Auth.Store` : GenServer et fichier JSON, décrit plus haut.
- `Kelescope.Auth.CA` : création de l'autorité, émission d'un certificat client
  (bibliothèque `x509`), construction du PKCS#12 par appel à
  `openssl pkcs12 -export` via `System.cmd/3`, clé et certificat passés sur
  l'entrée standard, jamais par fichier. OTP ne sait pas encoder du PKCS#12 ;
  `x509` non plus.
- `Kelescope.Auth.Passkey` : enveloppe `Wax` (bibliothèque `wax_`) : défis
  d'enregistrement et d'authentification, vérification, mise à jour du
  compteur. Origine et identifiant de partie liée déduits de la configuration
  `url` de l'endpoint.
- `Kelescope.Auth.Scope` : struct `%Scope{admin: %{id, level, domains}}` et
  prédicats `can?(scope, action, domain)`, `sees_domain?(scope, domain)`,
  `global?(scope)`. Assignée sous `current_scope`, nom déjà prévu par
  `Layouts.app/1`.
- `Kelescope.Auth.ClientCert` : `verify_fun/3`, extraction de l'empreinte
  depuis `get_peer_data/1`.
- `KelescopeWeb.Plugs.Auth` : lit le certificat, la session et le mode dev ;
  assigne `current_scope` ou redirige. Options `:require` avec `:authenticated`
  ou `:global_admin`.
- `KelescopeWeb.AuthHook` : `on_mount` équivalent pour LiveView, mêmes
  options, placé dans les `live_session` avant `LocaleHook`. Souscrit au topic
  `"auth:accounts"` : une révocation ou une désactivation coupe la session
  LiveView en cours, sans attendre le prochain montage.
- `KelescopeWeb.EnrollLive` (`/enroll`), `KelescopeWeb.LoginLive` (`/login`),
  `KelescopeWeb.SessionController` (`POST /session`, `DELETE /session`).
- Hook JavaScript `Passkey` (`assets/js/passkey.js`) : appelle
  `navigator.credentials.create` ou `.get` avec les options poussées par le
  LiveView, encode les tampons en base64url, renvoie le résultat par
  `pushEvent`. Signale l'absence de support WebAuthn.
- `Layouts.app/1` : identifiant et rôle du compte, liens vers `/account`, vers
  `/admins` pour un administrateur global, bouton « Déconnexion », bandeau du
  mode dev. Les liens vers le site Phoenix disparaissent.
- `CoreComponents.admin_confirm_modal/1` : le champ « Administrateur » est
  retiré ; l'événement de confirmation resoumet les `confirm_values` seuls.
  Les appelants prennent l'identifiant dans `current_scope`.
- Routeur : pipeline `:browser` complété par `KelescopeWeb.Plugs.Auth`, un
  `live_session :public` pour `/enroll` et `/login`, un `live_session
  :authenticated` pour les pages existantes et `/account`, un `live_session
  :global_admin` pour `/admins`.

### Pages existantes

- `ScenarioMonitorLive` (`kelescope_monitor`) : filtre les scénarios sur
  `sees_domain?/2` avant rendu, dans `mount` et dans chaque `handle_info` de
  poussée. Le `<select>` de la phase 2 ne propose que les domaines visibles. Le
  bouton « Arrêter » n'apparaît que si `can?(scope, :shutdown, domain)`, et le
  `handle_event` le revérifie.
- `DomainListLive` (`kelescope_domaines`) : même filtrage sur la liste et sur
  les poussées de compteurs ; « Recharger » et « Désenregistrer » soumis à
  `can?/3`.
- `McuLive` (`kelescope_mcu`) : conférences filtrées par domaine ; création,
  modification, destruction et enregistrement soumis à `can?/3` ; la liste
  déroulante des domaines du formulaire de création ne propose que la portée.
- Chaque `handle_event` d'action revérifie le droit. Un bouton masqué n'est pas
  une protection.

### `kelescope_admins` (nouvelle partie, paquet `kelescope-admins`)

`KelescopeWeb.AdminsLive` (`/admins`) et `KelescopeWeb.AccountLive`
(`/account`), avec leur backend Gettext (ADR-003). Les routes vivent dans le
socle (ADR-002).

### `kelescope-runtime`

- Dépendances : `wax_ ~> 0.7` (qui tire `x509`, `cbor`, `asn1_compiler`).
- `runtime.exs` : options TLS ci-dessus, variables ci-dessous, mode dev hors
  `:prod`.
- Spec RPM : `Requires: openssl` ; en `%post`, si `admins.json` est absent,
  affiche la commande d'amorçage.
- `rpm/kelescope.env` : nouvelles variables, commentées.

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

Rien. kelixip reçoit déjà un nom d'administrateur sur les actions tracées ; il
reçoit désormais un identifiant vérifié.

### Documentation

- `docs/maintenance/paquet-rpm.md` : nouvelles variables, amorçage,
  sauvegarde de `KELESCOPE_AUTH_DIR`, procédure de perte totale d'accès.
- `docs/utilisation/enrolement.md` : import du PKCS#12 dans Firefox, Chrome et
  le magasin système, redémarrage du navigateur, gestion des passkeys.
- `README.md` : titre et contenu de la phase 3.

## Tests

- `Kelescope.AuthTest` : amorçage refusé si des comptes existent ; invitation
  consommée une seule fois et expirée après le délai ; dernier administrateur
  global indésactivable et insupprimable ; révocation du dernier poste refusée ;
  `authenticate_certificate/1` distingue inconnu, révoqué, expiré, compte
  désactivé, valide.
- `Kelescope.Auth.StoreTest` : rechargement après écriture, écriture atomique
  (le `.tmp` n'est jamais lu), fichier absent, fichier corrompu.
- `Kelescope.Auth.CATest` : création de l'autorité, émission, empreinte
  stable, PKCS#12 relu par `openssl pkcs12 -info` avec le mot de passe.
- `Kelescope.Auth.PasskeyTest` : enregistrement et authentification avec les
  vecteurs de test fournis par `wax_` ; compteur de signature régressif refusé.
- `KelescopeWeb.Plugs.AuthTest` et `AuthHookTest` : sans certificat, certificat
  inconnu, révoqué, session sans certificat, empreinte de session différente du
  certificat présenté, compte désactivé pendant la session, mode dev.
- `KelescopeWeb.LoginLiveTest`, `EnrollLiveTest` : parcours complets avec un
  double du hook JavaScript (les cérémonies elles-mêmes sont couvertes par
  `PasskeyTest`).
- `KelescopeWeb.AdminsLiveTest`, `AccountLiveTest` : chaque action, chaque
  refus.
- Tests existants des trois pages : complétés par un cas `monitor / domaines`
  (les lignes des autres domaines absentes du rendu **et** des poussées ; aucun
  bouton d'action) et un cas `admin / domaines` (action refusée par le
  `handle_event` sur un domaine hors portée, même avec un événement forgé).
- Test manuel obligatoire avant livraison, dans Firefox et Chrome : enrôlement
  complet, redémarrage du navigateur, connexion, révocation du poste depuis un
  autre poste, déconnexion. L'authentificateur virtuel des outils de
  développement de Chrome suffit pour la passkey.

## Critères d'acceptation

- Sans certificat client, aucune page autre que `/enroll` et les fichiers
  statiques ne renvoie autre chose qu'une page de refus.
- Avec un certificat connu mais sans passkey, aucune session ne s'ouvre.
- Un compte `monitor / domaines` ne reçoit dans le DOM aucune donnée d'un autre
  domaine, y compris après une poussée en direct.
- Un compte `admin / domaines` ne peut pas déclencher une action sur un domaine
  hors portée, même en forgeant l'événement LiveView.
- La révocation d'un poste ou la désactivation d'un compte coupe les sessions
  LiveView ouvertes en moins de cinq secondes.
- Le nom tracé par kelixip est l'identifiant du compte connecté, jamais une
  saisie.
- Une release `:prod` ne peut pas démarrer en mode dev.
- `KELESCOPE_AUTH_DIR` restauré depuis une sauvegarde redonne tous les accès.

## Hors périmètre

- Enregistrer un certificat émis par une autre autorité (PKI d'entreprise).
  L'épinglage par empreinte le permet sans changer le modèle ; à traiter
  quand le besoin existe.
- OAuth / OpenID Connect.
- Plusieurs nœuds kelescope partageant un magasin de comptes.
- Journal d'audit dans kelescope (seul kelixip trace, comme en phase 2).
- Liste de révocation ou OCSP pour les certificats clients.
- Droits plus fins qu'un niveau et une portée.
- Pool de mediaservers et état de la connexion DB : les vues n'existent pas
  encore ; quand elles arriveront, elles seront réservées aux portées `all`.

## Risques

- **Connexion TLS réutilisée après enrôlement.** Le navigateur garde la
  connexion ouverte sans certificat et ne présente pas le nouveau certificat
  tant qu'elle vit. La page d'enrôlement demande de fermer le navigateur.
  C'est le piège le plus fréquent à prévoir en support.
- **Invite de sélection de certificat.** Chaque navigateur affiche la sienne,
  parfois sur chaque nouvelle connexion. Le comportement avec `cacertfile`
  renseigné est à valider sur Firefox et Chrome à l'implémentation.
- **`PHX_HOST` et l'identifiant de partie liée.** Un accès par adresse IP ou par
  alias DNS casse WebAuthn avec un message peu clair. Documenté dans
  `paquet-rpm.md` et affiché par `/login` quand l'hôte de la requête diffère
  de `PHX_HOST`.
- **Format du PKCS#12.** OpenSSL 3 chiffre en AES-256 avec PBKDF2 par défaut.
  Certains importeurs anciens exigent `-legacy` (RC2, 3DES). À vérifier sur les
  postes cibles ; l'option `-legacy` affaiblit la protection du fichier et ne
  doit pas devenir le défaut.
- **`verify_fun` permissive.** La couche TLS ne protège plus rien ; toute la
  protection tient au plug et au hook. Une route ajoutée hors des
  `live_session` protégées serait publique. Les tests du plug couvrent la
  liste des routes du routeur.
- **Perte de passkey ou de poste.** Un administrateur global réinitialise le
  compte. La perte de tous les administrateurs globaux se rattrape par
  `bootstrap/2` sur l'hôte, ce qui suppose l'accès shell : c'est la racine de
  confiance, à protéger comme telle.
- **Fichiers statiques publics.** `Plug.Static` sert le logo, le CSS et le
  JavaScript avant le routeur, donc sans authentification. Rien de sensible
  n'y figure ; à garder en tête pour tout ajout futur dans `priv/static`.
- **`wax_`** : un seul mainteneur, mais une bibliothèque active et largement
  téléchargée. Alternative écartée : `webauthn_components`, qui exige Ecto et
  LiveView 0.20.
- **Le cookie Erlang** reste un accès total au nœud kelixip (ADR-001). Cette
  phase n'y change rien.
