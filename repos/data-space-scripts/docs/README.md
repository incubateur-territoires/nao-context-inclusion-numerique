# Documentation — index

Repère pour retrouver la doc utile au projet. Pour le détail d'un sujet,
ouvrir le fichier correspondant.

## Suivi des évolutions

| Doc | Pour quoi |
|---|---|
| [../CHANGELOG.md](../CHANGELOG.md) | Journal des changements au fil de l'eau (tech + métier, avec hash et détails). Lecture dev/agent. |
| [../CHANGELOG-metier.md](../CHANGELOG-metier.md) | Même journal en version non-tech, sans noms. Lecture PO / partenaires / équipe métier. |

> Convention d'écriture (qui, quand, format) : voir `CLAUDE.md` à la racine, section *Documentation des changements*.
> Rattrapage manuel d'entrées oubliées : skill `/changelog` (`.claude/skills/changelog/SKILL.md`), avec en option une ref git ou une date de départ.

## Setup, infra, opérationnel

| Doc | Pour quoi |
|---|---|
| [DEV_SETUP.md](DEV_SETUP.md) | Installation locale, Docker Compose, Flyway, PostgreSQL/PostGIS, Metabase, troubleshooting |
| [POSTGREST.md](POSTGREST.md) | Architecture API REST (auth JWT, rôles, schémas exposés, ajout d'endpoint, OpenAPI) |
| [ci-cd-orchestrator.md](ci-cd-orchestrator.md) | DAGs orchestrateur, restore backups, rapports d'évaluation, règles de verdict |
| [../Apache_Airflow_Mattermost_Notifications.md](../Apache_Airflow_Mattermost_Notifications.md) | Notifications Mattermost depuis Airflow |

## Sources de données

Pour chaque source/DAG, deux niveaux de lecture :
- **Version technique** — Section 1 (vue d'ensemble + architecture), Section 2 (modèle de données : structures / personnes / affectations + activités/etc.), Section "Historique des fixes" en bas. Lecture dev/agent IA.
- **Version métier** — vue non-technique (sans jargon SQL, sans noms/prénoms), lecture PO / partenaires / équipe métier.

| Source / DAG | Version technique | Version métier |
|---|---|---|
| Coop / `coop-import` | [coop.md](coop.md) | [coop-metier.md](coop-metier.md) |
| Conseillers Numériques / `schema-idPoste` | [conseillers-numeriques.md](conseillers-numeriques.md) | [conseillers-numeriques-metier.md](conseillers-numeriques-metier.md) |
| Cartographie nationale / `carto-dag-import` | [cartographie-nationale.md](cartographie-nationale.md) | [cartographie-nationale-metier.md](cartographie-nationale-metier.md) |
| Aidants Connect / `aidants-connect-import` | [aidants-connect.md](aidants-connect.md) | [aidants-connect-metier.md](aidants-connect-metier.md) |

> ℹ️ Sections à compléter (suivi via le bloc *Statut* en haut de chaque doc source) : réconciliation cross-source aval (DAGs `*-similarities-merge`), pièges détaillés (§5), sous-systèmes idposte (postes/contrats/formations).

> 📌 **TODO — Section 3 (Réconciliation aval, DAGs `*-similarities-merge`)** :
> - Doc existante partielle : [`CONTACT_MERGE.md`](CONTACT_MERGE.md) §"`personne-similarities-dag.py` (fusion de doublons)" couvre la fusion contacts.
> - Code des deux DAGs : `structures-similarities-dag.py`, `personne-similarities-dag.py` à la racine.
> - À refaire si besoin (et seulement si besoin) : doc consolidée par DAG (algorithme winner/loser, seuils `similarity_threshold`, vues aval `dataviz.*` impactées). Pas urgent — les 4 docs sources signalent juste qu'un trigger lance ces DAGs en bout de chaîne.

### Doc transverse

| Doc | Pour quoi |
|---|---|
| [enrichissement-sirene-ban.md](enrichissement-sirene-ban.md) | Pipeline batch SIRENE + BAN, mutualisé par 3 sources (Coop, schema-idPoste, AC). Stratégies de fraîcheur, pièges, fail-fast token. |
| [questions-metier-en-cours.md](questions-metier-en-cours.md) | Liste des questions ouvertes pour Kevin / équipe métier (Q1-Q21 + notes amélioration + philosophie cross-source) |

## Métier — par sujet

| Doc | Pour quoi |
|---|---|
| [CONTACT_MERGE.md](CONTACT_MERGE.md) | Fusion des contacts (téléphone, courriels, site web) entre sources |
| [subventions-conseiller-numerique.md](subventions-conseiller-numerique.md) | Modèle subventions CN (deux enveloppes, bonifications, ETL, pièges) |

> Une MR en cours ajoute `ENRICHISSEMENT_ADRESSE.md` (pipeline d'enrichissement
> SIRENE+BAN, précédence adresse selon sémantique source, historique des fix).
> À croiser avec [enrichissement-sirene-ban.md](enrichissement-sirene-ban.md) quand mergée.

## Conventions

### Quand écrire de la doc ?

- **MR non-triviale** : si le changement touche un sujet déjà documenté
  → mettre à jour le doc concerné. Sinon, créer un nouveau
  `docs/SUJET.md` et l'ajouter à cet index.
- **Pas obligatoire** pour fix triviaux, refactos, renommages.

### Niveau attendu

La doc doit permettre à quelqu'un qui revient après une absence (ou
découvre le projet) de comprendre **ce qui se passe** et **pourquoi**.
Pas seulement décrire le code — l'expliquer.

- Pointeurs code : référencer `fichier:ligne` quand utile (à éviter
  pour des zones qui bougent souvent).
- **Historique des garde-fous** : quand un fix corrige un bug réel
  mesuré, citer le commit (hash court) et la cause dans la doc
  concernée. Précédent : `subventions-conseiller-numerique.md`
  §"Historique et évolution du modèle".

### Audience

Les docs sont écrites pour :
- l'équipe humaine (référents, collaborateurs, futurs contributeurs)
- les agents IA (Claude Code et autres) qui doivent raisonner sur le
  code sans deviner

### Wiki GitLab vs `docs/`

- **Wiki GitLab** : onboarding général, vue d'ensemble, FAQ
- **`docs/`** (ici) : architecture, règles métier, historique des
  décisions, runbooks. Versionné avec le code, lu en parallèle des
  fichiers source.

Les deux ne se remplacent pas — audiences différentes.
