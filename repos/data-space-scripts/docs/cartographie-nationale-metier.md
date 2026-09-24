# Cartographie nationale — vue métier

> Version non-technique de [`cartographie-nationale.md`](cartographie-nationale.md).
> Pour les détails d'implémentation, voir la doc technique.

## En quelques mots

La cartographie nationale regroupe tous les lieux de médiation numérique du pays en un seul référentiel mis à jour quotidiennement. Ces lieux proviennent de multiples sources (dispositifs nationaux, collectivités locales) que nous unifions, nettoyons et enrichissons pour alimenter la [cartographie publique](https://carto.beta.gouv.fr).

## Quelles données ramenées ?

Lieux de médiation numérique agrégés depuis les sources tierces (Hinaura, Fredo, Paca, Paris, etc.), normalisés et dédupliqués, enrichis avec l'identité légale (numéro SIRET via INSEE) et la géolocalisation (adresse précise via BAN), puis chargés dans la base entrepôt pour alimenter la cartographie publique. Chaque lieu peut être identifié par plusieurs sources — nous les unifions au lieu de créer des doublons.

## D'où viennent les données ?

Source unique : [mednum-cli](https://github.com/anct-cartographie-nationale/mednum-cli) — outil maintenu par ANCT qui agrège les données des sources tierces. Le dataspace l'exécute chaque jour à 1h du matin via la chaîne de validation automatisée.

## Règles métier importantes

1. **Identifiant unique par lieu** : Un lieu peut être répertorié par Coop, par les Conseillers Numériques, ou par la cartographie. Nous les unifions plutôt que de créer des doublons.
2. **Visibilité publique** : Une structure absente du nouvel import quotidien est masquée automatiquement de la carte publique (mais conservée en base pour traçabilité).
3. **Filtrage des identifiants trop longs** : Les lieux dont l'identifiant technique dépasse un seuil (2 000 octets) sont rejetés pour éviter une cascade d'erreurs. Ils sont tracés pour investigation auprès de la source.
4. **Désactivation Paca/Paris** : À chaque mise à jour quotidienne, les sources régionales Paca et Paris sont temporairement désactivées de la cartographie nationale, avec possible réassociation si elles sont présentes le lendemain. *Raison métier à clarifier (Q8).*

## Évolutions récentes (avril 2026)

- **Géolocalisation robuste** (27 avril) — ~512 lieux étaient envoyés dans le mauvais département par un rattrapage d'adresse trop permissif. Désormais le rattrapage n'est déclenché que si la source n'a pas fourni de coordonnées.
- **Structures sans adresse réparées** (13 avril) — 1 374 structures invisibles sur la carte à cause d'adresse manquante. Trois causes corrigées en 3 phases.
- **Identifiants trop longs filtrés** (20 avril) — La déduplication produisait des identifiants de plusieurs milliers d'octets → toute la mise à jour quotidienne échouait. Désormais filtrés et tracés pour investigation.
- **Conflits d'intégration corrigés** (13 avril) — L'intégration des structures pouvait échouer lors de fusion de doublons. Réécriture en traitement étape par étape.
- **Traçabilité ajoutée** (13 avril) — Possibilité de relier chaque entrée de la cartographie source à la structure consolidée pour diagnostiquer les rejets. Nouveau rapport de suivi.
- **Lecture d'adresse robuste** (20 avril) — Numéros type "21bis" correctement séparés, codes postaux et codes INSEE normalisés.

## Questions ouvertes côté métier

- **Q7** — Lien diagnostique temporairement orphelin quand un doublon est supprimé par le traitement aval. Intentionnel ou à corriger ?
- **Q8** — Raison précise de la désactivation Paca/Paris à chaque mise à jour quotidienne. Conflit de source ou isolation transitoire ?
- **Q9** — Qui ajoute / maintient les transformers mednum-cli ? Faut-il documenter le contrat pour éviter qu'un nouveau transformer casse l'import dataspace ?

Voir [`questions-metier-en-cours.md`](questions-metier-en-cours.md) pour le contexte complet.

## Pour aller plus loin

- Documentation technique : [`cartographie-nationale.md`](cartographie-nationale.md)
- Pipeline d'enrichissement adresse (MR en cours) : `ENRICHISSEMENT_ADRESSE.md`
- Questions métier en cours : [`questions-metier-en-cours.md`](questions-metier-en-cours.md)
- Historique global : [`../CHANGELOG-metier.md`](../CHANGELOG-metier.md)
