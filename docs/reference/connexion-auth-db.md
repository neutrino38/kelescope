# État de la connexion à la base `auth_db`

kelixip vérifie les mots de passe des comptes SIP dans une base de données. Ce
travail appartient à son module `auth_db`. kelescope affiche l'état de cette
connexion sur la page des scénarios.

## D'où vient la donnée

**`Kelix.Control.status/0` ne dit rien de cette connexion.** L'état vit dans le
module, donc derrière la commande de contrôle du module :

```
Kelix.Control.module_command("auth_db", "show", %{})
```

C'est la porte que `kelictl auth_db show` emprunte. `Kelescope.Kelixip.Control`
l'expose sous `module_command/4`.

`Kelescope.Kelixip.AuthDbPoller` l'appelle toutes les 20 secondes et republie
le résultat sur le topic `"kelixip:auth_db"`.

## Un échec se publie aussi

Les deux autres pollers gardent leur dernier succès et ne journalisent que
l'échec. Celui-ci publie aussi ses échecs.

La raison : cette page existe pour dire la vérité sur une connexion. Continuer
à afficher « connectée » après que le module a cessé de répondre serait un
mensonge, pas une approximation.

Trois échecs se lisent différemment à l'écran :

| Résultat | Affichage |
|---|---|
| `nil` | « en attente du premier relevé » |
| `{:error, :unknown_module}` | « module auth_db absent de cette instance » |
| tout autre `{:error, _}` | « état illisible » |

## Ce que chaque portée voit

Le détail nomme l'hôte, le port, la base et son utilisateur. C'est de la
configuration d'infrastructure.

- Portée `all` : tous les champs que le module rapporte. Ils vivent dans une
  section dépliable, repliée à l'arrivée sur la page. Le résumé, lui, reste
  toujours visible.
- Portée limitée à des domaines : seulement connectée, déconnectée, ou état
  inconnu. Aucune section à déplier, puisqu'il n'y a rien derrière.

## La forme rapportée

Relevée sur un nœud kelixip 1.5 vivant, par appel direct :

```elixir
{:ok,
 %{
   state: :up,
   host: "…",
   port: 3306,
   database: "…",
   username: "…",
   table: "os_subscriber",
   driver: :mysql,
   tls: true,
   certificate: "not verified",
   transport: "TLS, server certificate NOT verified (no ssl_ca_cert_file)",
   pool_size: 4,
   query_timeout_ms: 5000
 }}
```

`driver` est un atome, `port` et les durées des entiers, le reste des chaînes.

## Une seule clé porte le résumé

Le résumé connectée / déconnectée repose sur **une** clé, `state`. `up` vaut
connectée, `down` vaut déconnectée.

Toute autre valeur, et l'absence de la clé, s'affichent « état inconnu ».
Jamais « connectée ». Une page de supervision ne doit pas déclarer saine une
donnée qu'elle n'a pas su lire.

Le reste de l'affichage ne suppose aucune clé : le détail se rend champ par
champ, quels que soient les noms rapportés. Un changement de nommage dans le
module dégrade donc le résumé, jamais le détail.

## Le bouchon de dev n'est pas une preuve

`dev_support/kelix_control_stub.ex` répond à cette commande, avec les noms et
les types ci-dessus.

Un test qui passe contre le bouchon ne prouve pas pour autant que la page lit
un vrai nœud : le bouchon dit ce que nous croyons, pas ce que kelixip fait.
C'est exactement l'erreur qui a rendu cet état invisible pendant toute la
phase 2 — le bouchon inventait un `module_status.auth_db.connected` que
`status/0` ne renvoie jamais, et les tests le confirmaient consciencieusement.

Avant de faire dépendre une page d'un champ, relevez-le sur un nœud :

```
kelictl auth_db show
```
