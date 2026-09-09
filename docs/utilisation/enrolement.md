# Enrôler un poste

Pour entrer dans kelescope, vous devez prouver deux choses :

- **qui vous êtes**, avec une passkey ;
- **d'où vous venez**, avec un certificat installé dans votre navigateur.

Les deux sont exigés à chaque ouverture de session.

Décision : [ADR-004](../architecture/adr-004-authentification-passkey-certificat.md).

## Ce qu'il vous faut

- Un **code d'invitation**, donné par un administrateur général. Il est
  valable 24 heures et ne sert qu'une fois.
- Votre **identifiant** de compte, par exemple `prenom.nom`.
- Un moyen de créer une passkey : une clé de sécurité USB, votre téléphone,
  ou le gestionnaire de votre système (Windows Hello, Touch ID).

Une **passkey** est une clé secrète que votre appareil garde pour lui. Il
signe une question posée par kelescope, sans jamais donner la clé. Vous la
déverrouillez par un code ou votre empreinte.

## Les trois étapes

Ouvrez `https://<le nom de votre kelescope>/enroll`.

### 1. Votre code

Saisissez votre identifiant et votre code d'invitation.

### 2. Votre passkey

Donnez un nom à votre passkey, par exemple « clé jaune » ou « mon téléphone ».
Cliquez sur **Enregistrer la passkey**. Votre navigateur vous demande de la
créer, puis de la déverrouiller.

### 3. Votre poste

Donnez un nom à ce poste, par exemple « portable bureau ». Cliquez sur
**Émettre le certificat**.

kelescope affiche alors :

- un **mot de passe**, affiché une seule fois. Notez-le tout de suite.
- un **fichier `.p12`**, téléchargé automatiquement.

Ce fichier contient votre certificat. Il faut l'importer dans votre
navigateur.

## Importer le fichier

### Firefox

1. Menu ☰ → **Paramètres**.
2. Cherchez « certificats », puis cliquez sur **Afficher les certificats**.
3. Onglet **Vos certificats** → **Importer**.
4. Choisissez le fichier `.p12`, puis saisissez le mot de passe noté plus haut.

### Chrome et Edge, sous Windows

1. Double-cliquez sur le fichier `.p12`. L'assistant Windows s'ouvre.
2. Emplacement : **Utilisateur actuel**.
3. Saisissez le mot de passe.
4. Laissez Windows choisir le magasin automatiquement.

### Chrome, sous Linux

1. Menu ⋮ → **Paramètres** → **Confidentialité et sécurité** → **Sécurité**.
2. **Gérer les certificats** → onglet **Vos certificats** → **Importer**.
3. Choisissez le fichier `.p12`, puis saisissez le mot de passe.

## Fermez complètement le navigateur

**C'est l'étape que tout le monde oublie.**

Un navigateur garde ses connexions ouvertes. Une connexion ouverte avant
l'import ne présentera jamais votre nouveau certificat. Vous verrez encore
« Poste non enrôlé », même après un import réussi.

Fermez **toutes** les fenêtres du navigateur, puis rouvrez-le.

Sous Windows, vérifiez aussi qu'aucune icône du navigateur ne reste dans la
zone de notification.

## Vous connecter

Revenez sur kelescope.

1. Le navigateur vous demande quel certificat présenter. Choisissez celui à
   votre nom.
2. kelescope affiche « Poste reconnu ». Cliquez sur **Se connecter**.
3. Déverrouillez votre passkey.

Vous êtes connecté. La session dure 12 heures.

## Gérer vos passkeys et vos postes

La page **Mon compte** liste vos passkeys et vos postes.

- **Ajouter une passkey** : utile pour avoir un second moyen d'entrer, par
  exemple une clé de secours rangée ailleurs.
- **Émettre un certificat** : à faire depuis chaque nouveau poste, ou pour un
  second navigateur. Le fichier et son mot de passe s'obtiennent comme à
  l'étape 3.
- **Révoquer** : un poste perdu ou volé perd l'accès immédiatement, même s'il
  a une session ouverte.

Vous ne pouvez révoquer ni votre dernière passkey, ni votre dernier poste, ni
le poste que vous utilisez à cet instant. Sinon vous vous enfermeriez dehors.

## Quand ça ne marche pas

| Ce que vous voyez | Ce qui se passe | Quoi faire |
|---|---|---|
| « Poste non enrôlé » après un import | La connexion du navigateur est plus ancienne que le certificat. | Fermez complètement le navigateur, puis rouvrez-le. |
| « Poste refusé » | Le certificat est inconnu, révoqué ou expiré. | Demandez une réinitialisation à un administrateur général. |
| Le navigateur ne propose aucun certificat | L'import a échoué, ou il a été fait dans un autre profil. | Refaites l'import dans le profil que vous utilisez. |
| La passkey échoue avec un message obscur | Vous appelez kelescope par une adresse IP ou un autre nom. | Utilisez exactement le nom d'hôte indiqué par votre exploitant. |
| Vous avez perdu passkey et poste | Rien à récupérer de votre côté. | Un administrateur général réinitialise votre compte et vous redonne un code. |

## Pour l'exploitant

Amorçage du premier compte, sauvegarde et perte totale d'accès :
[docs/maintenance/paquet-rpm.md](../maintenance/paquet-rpm.md).
