# ADR-004 : Authentification des administrateurs par passkey et certificat client

## Statut
Accepté.

## Contexte

kelescope n'a aucune authentification. Toute personne qui atteint le port
HTTPS voit tout et peut tout faire : arrêter un scénario, désenregistrer un
contact, détruire une conférence. Le nom d'administrateur demandé avant une
action destructrice est une saisie libre, tracée par kelixip sans
vérification (phase 2). [ADR-001](adr-001-connexion-kelixip.md) le rappelle :
tout accès à kelescope équivaut à un accès total au nœud kelixip.

Le README prévoyait d'abord une authentification OAuth, avec Google, Microsoft
et une alternative libre.

Quatre contraintes pèsent sur le choix :

- kelescope tourne sur un réseau de management. Ce réseau n'a pas toujours
  d'accès sortant vers Internet, et le poste de l'administrateur n'y accède pas
  toujours non plus.
- Les administrateurs se comptent sur les doigts d'une main par instance.
- kelescope n'a pas de base de données, et n'en veut pas pour si peu de
  comptes.
- Un exploitant doit pouvoir rétablir l'accès depuis le shell de l'hôte, sans
  service tiers.

## Options

**OAuth / OpenID Connect avec un fournisseur d'identité.** Google et Microsoft
pour les comptes d'entreprise, Keycloak ou équivalent pour une alternative
auto-hébergée. Avantages : authentification unique, second facteur délégué,
révocation centrale. Inconvénients : le navigateur et kelescope doivent joindre
le fournisseur, ce qui contredit la première contrainte ; un secret client à
protéger par instance ; un mapping entre groupes du fournisseur et rôles de
kelescope à maintenir ; pour l'alternative libre, un service de plus à opérer.
Rien n'attache l'accès à un poste précis.

**Mot de passe et code TOTP, comptes locaux.** Aucune dépendance. Mais le
mot de passe se vole par phishing, il faut une politique de mots de passe, et
rien n'attache l'accès à un poste.

**Passkey WebAuthn et certificat client mTLS, comptes locaux.** La passkey
(FIDO2 : clé de sécurité, Touch ID, Windows Hello) prouve la personne, avec
vérification locale par code ou biométrie. Le certificat client prouve le
poste. Tout fonctionne hors ligne. La révocation d'un poste est immédiate.
Inconvénients : un enrôlement en deux temps (passkey, puis import d'un fichier
PKCS#12 dans le navigateur), un import pénible sur mobile, une invite de
sélection de certificat propre à chaque navigateur, et une page d'enrôlement
atteignable sans certificat.

**Certificat client seul.** Le plus simple à déployer. Un seul facteur : un
poste déverrouillé suffit pour agir sur la production.

## Décision

Passkey WebAuthn **et** certificat client, avec des comptes locaux.

- **L'identité d'un poste est l'empreinte de son certificat**, enregistrée dans
  le compte. kelescope émet les certificats avec sa propre autorité de
  certification, mais ne fait pas confiance à cette autorité pour identifier :
  un certificat dont l'empreinte n'est pas enregistrée est refusé, même signé
  par elle. Révoquer un poste, c'est retirer une empreinte. Aucune liste de
  révocation. La compromission de la clé de l'autorité ne donne aucun accès.
- **La passkey est obligatoire à chaque ouverture de session.** Le certificat
  seul ne suffit jamais.
- **Un compte se crée sur invitation.** Un administrateur global crée le compte
  et obtient un code d'invitation à usage unique, limité dans le temps. Le
  nouvel administrateur s'enrôle lui-même avec ce code : il enregistre sa
  passkey, puis télécharge son certificat. Le premier administrateur global se
  crée depuis le shell de l'hôte.
- **Les comptes vivent dans un fichier JSON** sous `/var/lib/kelescope`, écrit
  par un seul processus. Lisible par l'exploitant, sauvegardable avec `cp`.
- **Quatre rôles**, produit d'un niveau (moniteur ou administrateur) et d'une
  portée (toute l'instance ou une liste de domaines). Seul l'administrateur
  global gère les comptes.
- **Un mode dev** désactive tout cela hors production : l'application se
  comporte comme si un administrateur global était connecté. Ce mode ne peut
  pas s'activer dans une release de production.

## Conséquences

- Le nom tracé par kelixip lors d'une action destructrice devient l'identifiant
  du compte connecté. La saisie libre disparaît.
- Un rôle limité à des domaines impose un filtrage **côté serveur** de tout ce
  qui est rendu : scénarios, domaines, conférences. Le filtre d'affichage de la
  phase 2 ne suffit pas.
- Le paquet `kelescope-runtime` doit être relivré : nouvelles dépendances
  (`wax_`, `x509`), configuration TLS dans `runtime.exs`, dépendance système
  `openssl` pour produire les fichiers PKCS#12.
- Le socle `kelescope-core` porte la frontière de sécurité : magasin de
  comptes, autorité de certification, plug et hook d'authentification, pages
  de connexion et d'enrôlement. La gestion des comptes est une page de plus,
  livrée dans son propre paquet.
- `PHX_HOST` devient critique : c'est l'identifiant de partie liée WebAuthn.
  Le navigateur doit appeler kelescope exactement par ce nom d'hôte.
- Après mise à jour vers cette version, kelescope refuse tout accès jusqu'à
  l'amorçage du premier compte depuis le shell.
- Le pouvoir du cookie Erlang partagé avec kelixip ne change pas. Cette
  décision protège l'accès à kelescope. Elle ne réduit pas ce que kelescope
  peut faire sur le nœud kelixip.

Détails d'implémentation : [docs/conception/phase3-auth/SPEC.md](../conception/phase3-auth/SPEC.md)
