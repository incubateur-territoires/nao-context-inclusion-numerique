# 16 — Architecture de code : Functional Core, Imperative Shell (FCIS)

> Décision : le code du pipeline suit le pattern **FCIS** — la logique métier vit dans des
> fonctions pures, l'infrastructure (Airflow, PostgreSQL, HTTP) dans une coquille qui ne
> fait que brancher. L'architecture hexagonale formelle (ports & adapters avec interfaces)
> a été évaluée et écartée — voir plus bas.

## Le problème constaté

La logique métier du pipeline vit **à l'intérieur** de l'infrastructure. Exemple canonique :
`_transform_data()` dans `etl/extract/connectors/http_airflow.py` — ~400 lignes de règles
métier coop (mapping des champs, choix du pivot SIRET/RNA, normalisation des noms, filtres
carto) enfouies dans un opérateur Airflow qui fait aussi du HTTP, de la pagination et de
l'écriture PostgreSQL.

Conséquences observées :

- **Intestable sans artifice** : tester une simple fonction de mapping JSON exige de
  stubber les modules Airflow (vécu dans `tests-unitaires/conftest.py`).
- **Bugs invisibles** : le bug `deleted_at_coop` (http_airflow.py:910, 100 % NULL sur
  162 948 lignes) a vécu des mois sans détection — aucun test ne pouvait exister sur du
  code inséparable de son runtime.
- **Inréutilisable** : impossible de rejouer une transformation hors DAG (backfill,
  debug local, notebook d'analyse).
- **Illisible** : la règle métier ("si SIRET et RNA coexistent, le RNA est perdu") se
  découvre en lisant du code d'opérateur, pas en lisant une fonction nommée.

## Le pattern FCIS

Deux zones, une frontière stricte :

```
┌─────────────────────────────────────────────────────────────────┐
│  SHELL (imperative)  — opérateurs Airflow, *-dag.py, adapters   │
│  Tout l'I/O : HTTP, capture source.*, lecture/écriture PG.      │
│  Aucune logique métier. Le shell a le droit d'être ennuyeux.    │
│                                                                 │
│        lire ──►  ┌───────────────────────────┐  ──► écrire      │
│                  │  CORE (functional)        │                  │
│                  │  Fonctions pures :        │                  │
│                  │  données → données.       │                  │
│                  │  ZÉRO I/O, zéro effet     │                  │
│                  │  de bord, zéro Airflow.   │                  │
│                  └───────────────────────────┘                  │
└─────────────────────────────────────────────────────────────────┘
```

### Les règles

1. **Le core est pur.** Une fonction du core prend des données (dict, DataFrame, dataclass)
   et en rend. Interdits absolus : connexion DB (même en paramètre), appel réseau, lecture
   de fichier, variable d'environnement, horloge (`datetime.now()` — l'instant est passé en
   paramètre), import Airflow.
2. **Le shell ne décide rien.** Il séquence : lire → appeler le core → écrire. Toute
   condition qui relève du métier ("exclure si déjà sur la carto") appartient au core ;
   toute condition qui relève de la plomberie ("retry si 429") appartient au shell.
3. **La frontière est un type de données, pas une abstraction.** Le shell passe au core
   du brut (le JSONB de `source.*`, tel quel) ; le core rend des lignes prêtes à charger.
   Pas d'interface entre les deux — juste des données.
4. **Concession unique côté shell : le sink injecté.** Quand un morceau de shell doit être
   composable (capture brute optionnelle), on injecte une *fonction* — pattern
   `make_source_sink` existant. C'est un port au sens hexagonal, version idiomatique
   Python : une fonction, pas une interface.

### Emboîtement avec le pattern bronze (fiche 15)

FCIS et "bronze d'abord" sont les deux faces du même découpage :

```
SHELL : appel API ──► capture brute source.* ──►  ...  ──► écriture main/import
                                                   ▲
CORE  :                        source.* (JSONB) ── transformer() ──► lignes finales
```

- La **capture brute** est du shell : de l'I/O pur, avant toute décision.
- La **transformation** est du core : `source.*` en entrée, lignes en sortie, rejouable
  à l'infini sur le même brut (reproductibilité, principe non négociable n° 3 du README).
- La **base comme interface** (run_id + source_key) remplace le XCom côté shell.

Chaque flux migré vers le bronze (chemin de migration de la fiche 15) applique FCIS
par construction : sa nouvelle transformation naît en fonction pure.

## Pourquoi pas l'architecture hexagonale formelle

Évaluée (l'équipe la connaît) et écartée pour ce projet — au sens "ports & adapters avec
interfaces (`Protocol`/ABC), domaine appelant ses ports" :

| Critère | Hexagonal formel | FCIS |
|---|---|---|
| Forme du problème | Domaine interactif qui dialogue avec ses ports en cours de traitement (appli transactionnelle) | Pipeline linéaire lire → transformer → écrire — la forme d'un ETL batch |
| Coût du test | Écrire et maintenir un fake par port | Aucun : entrée → sortie → assert |
| Cérémonie Python | Protocols, classes abstraites, adapters nommés — étranger à ce codebase procédural | Des fonctions qui prennent et rendent des dicts/DataFrames |
| Bénéfice différentiel ici | Substituabilité de l'infra (PG → autre chose) : besoin inexistant à ce jour | Testabilité immédiate : LE besoin criant (0 test en CI) |

Le mix retenu : **grille hexagonale à la frontière** (des fonctions injectées comme ports
fins, cf. règle 4), **FCIS à l'intérieur** (le métier est pur, jamais d'I/O même abstrait).

**Signal de bascule** (même logique que la fiche 14) : si un jour le même core doit tourner
sur deux infrastructures réellement différentes (ex. hors Airflow chez un partenaire), on
formalisera les ports concernés — et uniquement ceux-là.

## Organisation cible du code

```
etl/
  core/                 ← fonctions pures, une par flux ou par étape
    coop.py             ←   ex. transformer_structures(items: list[dict]) -> DataFrame
    ...
  extract|load/...      ← shell existant (adapters, opérateurs)
*-dag.py                ← shell : orchestration seulement
tests-unitaires/
  <source>/             ← tests du core : payloads locaux, zéro stub nécessaire
```

`etl/core/` n'importe **jamais** `airflow.*`, `psycopg2`, `requests`. Cette règle est
vérifiable mécaniquement (grep en revue de MR, lint dédié à terme).

## Chemin d'adoption — non intrusif

1. **Aucun refactoring de l'existant pour le principe.** Pas de filet (pas de tests en CI),
   donc pas de chirurgie sur du code vivant. `http_airflow.py` reste en place.
2. **La règle s'applique au code neuf** : toute nouvelle logique métier naît dans
   `etl/core/`, avec ses tests. Critère de revue de MR en 10 secondes : "y a-t-il une
   règle métier dans un opérateur ou un DAG ?"
3. **La migration bronze est le véhicule** : chaque flux migré (ordre fiche 15 : coop →
   BAN → carto → AC quotidien) voit sa transformation réécrite en fonction pure dans le
   core + testée. L'ancien code meurt par remplacement, pas par refactoring.
4. **Prérequis transverse** : les tests du core tournent en CI (`tests-unitaires/`,
   environnement uv autonome). Une règle d'architecture non vérifiée automatiquement
   meurt en trois mois.

## Pièges connus

- **Le core qui triche** : une fonction "pure" qui lit une variable d'environnement ou
  appelle `datetime.now()` n'est plus rejouable. Tout ce qui varie est un paramètre.
- **Le shell qui gonfle** : un `if` métier glissé dans l'opérateur "parce que c'est plus
  simple là". C'est exactement comme ça que `http_airflow.py` est devenu ce qu'il est.
- **L'abstraction prématurée** : créer des ports/interfaces "au cas où". On ne formalise
  un port qu'au signal de bascule, jamais avant.
- **La migration à moitié** : réécrire la transformation dans le core mais laisser
  l'ancienne active dans l'opérateur → deux vérités. Une bascule de flux remplace, elle
  ne duplique pas (même piège que fiche 15).
