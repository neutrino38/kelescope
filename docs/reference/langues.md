# Langues servies par kelescope

kelescope sert le français et l'anglais. Le français est la langue par défaut.

## Comment une requête obtient sa langue

Trois sources, dans cet ordre.

1. **Le choix mémorisé.** La session porte la clé `locale`. Le sélecteur
   « FR / EN » appelle `GET /locale/:locale`, qui écrit ce choix dans la
   session, puis renvoie sur la page d'où vient la demande.
2. **La langue du navigateur.** Sans choix mémorisé, le plug `:put_locale` du
   routeur lit l'en-tête `accept-language` de la requête.
3. **Le défaut.** Faute des deux, le français.

Le plug écrit ensuite la langue retenue dans la session. C'est ce qui la rend
visible au montage d'un LiveView : un LiveView qui se connecte par websocket
voit la session, jamais les en-têtes de la requête.

`KelescopeWeb.LocaleHook` repose la langue dans le processus du LiveView, qui
n'est pas celui du plug. `Gettext` garde la langue par processus.

## Où s'affichent les réglages de lecture

Deux réglages vont toujours ensemble : la langue et la taille du texte.

- `CoreComponents.locale_switch/1` : le sélecteur « FR / EN ».
- `CoreComponents.font_size/1` : les boutons « A- / A+ ».

Toute page doit offrir les deux.

- Les pages authentifiées les obtiennent par `CoreComponents.nav/1`, qui
  appelle les deux composants.
- `/login` et `/enroll` n'affichent aucune barre de navigation. Elles appellent
  donc les deux composants elles-mêmes.

**Piège.** Une nouvelle page sans barre de navigation doit appeler ces deux
composants. Sans eux, la personne qui ne lit pas le français, ou qui a besoin
d'un texte plus grand, n'a aucun moyen de régler la page. Le cas est le plus
grave avant la connexion : un poste refusé ne voit qu'un message, et il doit
pouvoir le lire.

`font_size/1` s'appuie sur `window.kelescopeBumpFont`, défini dans la
disposition racine `root.html.heex`. Toute page en dispose donc.

## Négociation de `accept-language`

`KelescopeWeb.Locale.from_accept_language/1` applique ces règles.

- La comparaison porte sur la sous-étiquette de langue seule : `en-GB` choisit
  `en`.
- Les étiquettes se trient par qualité `q` décroissante. Sans `q`, la qualité
  vaut 1.
- Une étiquette que l'en-tête refuse par `q=0` n'est jamais choisie.
- Une étiquette que kelescope ne sert pas est ignorée. `*` ne choisit rien.

Exemple : `de-DE,de;q=0.9,en;q=0.5` donne `en`.

## Piège : la déconnexion oublie le choix

`DELETE /session` vide la session, donc le choix de langue avec elle. La langue
revient alors à celle du navigateur. C'est le comportement voulu : le choix ne
vit que dans la session, et la détection donne un résultat raisonnable sans
aucun réglage.

## Où vivent les traductions

Chaque partie porte son propre backend `Gettext` et son propre catalogue
`priv/gettext`. Décision et conséquences :
[ADR-003](../architecture/adr-003-backend-gettext-par-partie.md).

Les `msgid` sont en français. Le catalogue `en` porte les traductions
anglaises.

Après avoir ajouté ou modifié une chaîne dans une partie :

```
cd apps/<partie>
mix gettext.extract --merge
```

Puis remplir les `msgstr` vides de `priv/gettext/en/LC_MESSAGES/default.po`.

`mix gettext.extract --check-up-to-date`, lancé dans une partie, dit si son
catalogue a pris du retard sur le code.
