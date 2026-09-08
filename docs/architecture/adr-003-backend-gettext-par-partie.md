# ADR-003 : Un backend Gettext par partie

## Statut
Accepté. Amende l'invariant « toutes les traductions dans le socle » de
[ADR-002](adr-002-decoupage-paquets-rpm.md).

## Contexte

Le découpage décidé en [ADR-002](adr-002-decoupage-paquets-rpm.md) place le
socle et chaque page dans un paquet distinct. Il prévoyait un seul backend
Gettext, dans le socle, au motif qu'un backend compile les traductions qu'il
sert.

Le comptage des appels dans le code contredit ce choix.

| Partie | Appels à `gettext` |
|---|---|
| `kelescope_mcu` | 69 |
| `kelescope_monitor` | 42 |
| `kelescope_domaines` | 21 |
| `kelescope_core` | 18 |

132 des 150 chaînes traduisibles appartiennent aux pages, pas au socle. Un
backend unique dans le socle ferait donc dépendre presque tout changement de
texte d'une livraison du socle.

`mix gettext.extract` aggrave le point. La tâche écrit dans le `priv/gettext`
de l'application courante. Lancée depuis une partie, elle ne sait pas alimenter
le catalogue du socle : chaque extraction demanderait un report manuel.

## Décision

Chaque partie porte son propre backend Gettext et son propre
`priv/gettext`. Les traductions d'une page sont livrées dans le paquet de cette
page.

`KelescopeWeb.__using__` accepte le backend en second élément :

```elixir
use KelescopeWeb, {:live_view, KelescopeWeb.Mcu.Gettext}
```

Sans second élément, le backend du socle `KelescopeWeb.Gettext` s'applique.

La langue est posée **globalement** pour le processus, par
`Gettext.put_locale/1`, et non par backend. Tous les backends la lisent. Le plug
`:put_locale` du routeur et `KelescopeWeb.LocaleHook` procèdent ainsi.

## Conséquences

- Une chaîne nouvelle ou modifiée dans une page se livre dans le paquet de cette
  page. Le socle ne bouge pas.
- `mix gettext.extract` puis `mix gettext.merge` se lancent par application.
- Une même chaîne employée par deux pages est traduite deux fois, une fois dans
  chaque catalogue. C'est le prix de l'indépendance ; le surcoût mesuré est de
  7 entrées sur 132.
- Poser la langue par backend (`Gettext.put_locale/2`) casse l'affichage : les
  pages resteraient dans la langue par défaut. Un test l'éprouve, en vérifiant
  qu'une page sert bien l'anglais pour ses propres chaînes **et** pour celles du
  socle.
- L'invariant 2 d'ADR-002 ne bouge pas : le CSS et le JavaScript restent uniques
  et vivent dans le socle. Seules les traductions se décentralisent.
