# Cycle de vie des lieux et des personnes — matrice de preuve

*Chaque assertion des documents [`cycle-de-vie-lieux-personnes.md`](cycle-de-vie-lieux-personnes.md)
et [`cycle-de-vie-lieux-personnes-support.md`](cycle-de-vie-lieux-personnes-support.md),
découpée en sous-assertions par strate, avec un pointeur vers sa preuve.*

> **Méthode.** Une assertion du doc narratif fait presque toujours jouer
> plusieurs strates (app coop, SQL dataspace, filet ETL, loaders MIN, front
> carte). Ici, chaque assertion reçoit un identifiant, est découpée en
> sous-assertions **par module qui l'influence**, et chaque sous-assertion
> pointe vers sa preuve avec un **statut honnête** — jamais « testé » si ce
> n'est pas testé. Les ❌ sont des trous de preuve assumés : chacun est un
> candidat de test à créer (liste récapitulative en fin de document).
>
> Inventaire initial : 17/09/2026. Les pointeurs 📄 sont datés par nature :
> vérifier le code avant de s'y fier des mois plus tard.

## Statuts de preuve

| Statut | Signification | Force |
|---|---|---|
| ✅ **TU-CI** | test unitaire dans `tests-unitaires/`, **bloquant en CI** (une MR qui le casse ne merge pas) | la plus forte : la preuve se défend toute seule |
| 🧪 **TI-manuel** | test d'intégration automatisé dans `tests/` (nécessite `DATABASE_URL`), **hors CI** — exécution manuelle | forte, mais peut se périmer sans bruit |
| 🔎 **sondé** | invariant prod rejouable (SQL lecture seule) — prouve l'*état observé*, pas le code | complémentaire des tests |
| 📄 **constaté** | vérifié par lecture de code à la date indiquée (pointeur fichier) | la plus faible — se périme |
| 🤝 **chez la coop** | la preuve vit dans le repo coop (leurs tests, leur CI) — on pointe, on ne possède pas | à faire acker par eux |
| ❌ **à créer** | aucune preuve automatisée — trou assumé | candidat de ticket |

⚠️ Constat structurel d'entrée : **la CI GitLab ne bloque que sur
`tests-unitaires/`**. Toute la spec exécutable carto (`tests/carto/`) est
🧪 TI-manuel — la brancher en CI est l'action la plus rentable de ce document
(→ A-01).

---

## T — Assertions transversales (arbitrage et suppression)

### T-01 « Un `updated_at` par source ; `updated_at` global = colonne générée, jamais écrite »

| Sous-assertion | Module | Preuve |
|---|---|---|
| `lieu_inclusion.updated_at` est `GENERATED ALWAYS` (GREATEST des 3) | migration (V153/V163) | 📄 catalogue pg (`\d main.lieu_inclusion`) — ❌ TI à créer : un UPDATE de `updated_at` doit échouer |
| aucun écrivain ne tente d'écrire `updated_at` | filet ETL | ✅ TU-CI `tests-unitaires/coop/test_registre_lieux_coop.py` (les SQL du filet n'écrivent que `updated_at_coop`) |
| idem côté coop (modèle Prisma en `dbgenerated`) | app coop | 🤝 PR coop #615 (schéma Prisma) |
| idem côté MIN (modèle Prisma) | MIN | 📄 schéma Prisma min (17/09/2026) |

### T-02 « En cas de conflit, le plus frais gagne — à dates honnêtes »

| Sous-assertion | Module | Preuve |
|---|---|---|
| l'enrichissement carto d'une ligne commune n'écrase que si plus frais | `carto-dag-import.py` | 📄 (17/09/2026) — ❌ TU à créer sur la fonction de merge |
| personnes : AC n'update que si `updated_at_ac` amont > local | `etl/load/aidants_connect.py` | 📄 UPDATE conditionnel — ❌ TU à créer (le SQL est inline, non extrait dans core/) |
| ⚠️ les dates coop antérieures au 07/07/2026 ne sont PAS honnêtes (bumps de masse) | donnée prod | 🔎 constat chiffré (12 086/12 708) — pas de sonde permanente ; limite documentée, pas corrigée |

### T-03 « Une valeur bat un vide ; un NULL externe n'écrase jamais »

| Sous-assertion | Module | Preuve |
|---|---|---|
| id-poste ne remplace jamais une valeur existante (COALESCE) | `schema-idPoste.py` | 📄 `process_personne_upsert_file` — ❌ TU à créer |
| contact lieu : combinaison clé par clé, l'archive comble les trous coop | V160 (backfill) + filet | ✅ TU-CI `test_registre_lieux_coop.py` (expressions du filet) + 🔎 divergences prod = `contact.*` seul |
| contact personne : fusion JSONB `contact \|\| EXCLUDED.contact` | `schema-idPoste.py` | 📄 — ❌ TU à créer |

### T-04 « L'effacement humain retire SA contribution ; jamais d'arbitrage silencieux (difftool) »

| Sous-assertion | Module | Preuve |
|---|---|---|
| le difftool est présenté avant modification d'un lieu divergent | app coop | 🤝 PR coop #615 (leurs tests UI) — nous n'avons AUCUNE preuve de notre côté |
| la vue divergences fournit le matériau exact du difftool | V161/V166 | 🧪 TI-manuel partiel (contrôle de santé §1-2) — ❌ TI dédié à créer (cas synthétiques par champ) |

### T-05 « Toute réconciliation gardée par date est aveugle → le filet compare les valeurs »

| Sous-assertion | Module | Preuve |
|---|---|---|
| `SQL_RAFRAICHIR_METIER` compare les 20 champs par valeur, pas par date | filet | ✅ TU-CI `test_registre_lieux_coop.py` (ordre des requêtes + clés du bilan) |
| le rattrapage est idempotent (2ᵉ passage = 0 ligne) | filet | 🔎 logs quotidiens `metier_rafraichi = 0` + contrôle de santé §3 — ❌ TI à créer (rejouer 2× en transaction) |

### T-06 / T-07 / T-08 « Rien n'est supprimé physiquement — sauf fusion »

| Sous-assertion | Module | Preuve |
|---|---|---|
| aucun DAG dataspace ne DELETE un lieu ou une personne (hors fusion) | tous les DAGs | 📄 revue exhaustive 17/09/2026 (grep DELETE) — invariant non testable simplement ; re-vérifier à chaque nouveau DAG |
| fusion personnes : DELETE de la perdante + journal d'audit | `personne-reconciliation-dag.py:308` | 📄 + 🔎 `audit.personne_merge_log` (toute disparition doit avoir sa ligne) — ❌ TU à créer sur la fonction de fusion |
| fusion lieux coop : DELETE physique du lieu source | coop `mergeLieuInclusion.ts` | 📄 (17/09/2026) — 🤝 leurs tests |
| fusion lieux coop : écho `deleted_at` au référentiel (`retirerDuRegistre`, coop 11/09/2026) | coop `fusionner-des-lieux.mutation.ts` | 🤝 leur test `fusionner-des-lieux.steps.ts` (« couvrir la répercussion de la fusion au registre ») |
| suppression PHYSIQUE coop sans écho → l'inscription orpheline est retirée par le filet (`deleted_at`, identité conservée, idempotent) | filet `SQL_RETIRER_ORPHELINS` (SEPT #1950) | 🧪 TI-manuel `tests/coop/test_filet_registre_lieux.py` (filet ENTIER sur base, commit neutralisé, 4 cas) + ✅ TU-CI ordre/bilan `test_registre_lieux_coop.py` + 🔎 contrôle §7 (5 orphelins constatés le 16/09, 0 attendu après le premier filet) |

---

## L — Les lieux

### L-01 « La double écriture coop : update / adoption / insert, dans la même transaction »

| Sous-assertion | Module | Preuve |
|---|---|---|
| les 3 chemins + la transaction unique | app coop | 🤝 PR coop #615 — revue croisée faite (sept. 2026), aucune preuve chez nous |
| l'adoption ne peut pas violer la contrainte unique `carto_id` | app coop + contrainte SQL | 📄 contrainte unique (catalogue) + 🤝 |
| filet = filet, pas concurrent : il n'insère que les manquants | filet | ✅ TU-CI `test_registre_lieux_coop.py` |
| preuve de vie en prod (écritures signées `edited_by='coop'`, source posée) | prod | 🔎 contrôle de santé §5 |

### L-02 « Grants et périmètre d'écriture du rôle coop (documentaires, sonum propriétaire) »

| Sous-assertion | Module | Preuve |
|---|---|---|
| les grants V160 listent le périmètre officiel | V160 | 📄 migration — vérifiable par `\dp` |
| l'app coop se connecte en `sonum`, propriétaire | infra coop | 🤝 vérifié par la coop (10/09/2026) — invérifiable de notre côté, dette de gouvernance #1943 |

### L-03 « Le filet : manquants → adresses → compteurs → métier, avec bilan »

| Sous-assertion | Module | Preuve |
|---|---|---|
| ordre des requêtes et clés du bilan (`metier_rafraichi`, `compteurs_rafraichis`, `reste_sans_registre`) | filet | ✅ TU-CI `test_registre_lieux_coop.py` |
| invariant « 0 lieu coop vivant sans inscription » | prod | 🔎 contrôle de santé §4 |
| `mediateurs_en_activite` = compte réel côté coop | filet | 🔎 contrôle §3 — ❌ TI à créer (cas : période terminée hier → compteur décrémenté) |

### L-04 « Listes vides : `{}` ≡ NULL des deux côtés des comparateurs »

| Sous-assertion | Module | Preuve |
|---|---|---|
| comparateurs du filet normalisés (`NULLIF(..., '{}')`) | filet | ✅ TU-CI (expressions dans les SQL testés) |
| vue divergences normalisée | V166 | 🔎 contrôle §1 (plus aucune fausse divergence liste) — ❌ TI à créer (cas synthétique `[]` vs NULL → 0 divergence) |

### L-05 « Critères d'affichage carte d'un lieu : référencé + visible + non supprimé »

| Sous-assertion | Module | Preuve |
|---|---|---|
| le WHERE d'`api.carto` (3 conditions, `deleted_at` pour toutes les origines) | V167 | 🧪 TI-manuel `tests/carto/cas_cycle_de_vie_lieux.yml` (cas lieu-seul : `min_supprime_mais_visible`, `coop_supprime_present`, `min_cree_sans_reference`, `coop_masque_present`) + `cas_visibilite.yml` via les personnes |
| un lieu supprimé disparaît de la carte, quelle que soit son origine | V167 | 🧪 idem + 🔎 contrôle §6 (suppressions propagées) |
| le drapeau visible d'un lieu coop = choix coop | filet + double écriture | 🔎 contrôle §3 (le filet réaligne `visible`) |

### L-06 « Le fichier national ne pilote l'état que des lignes externes (ni coop, ni touchées par MIN) et ne rallume jamais un lieu supprimé »

Réécrite le 18/09/2026 (SEPT #1950) : le SQL de la tâche `integration_lieux` est
extrait dans `etl/load/carto_integration_lieux.py` et **exécuté tel quel** par
la spécification `tests/carto/cas_cycle_de_vie_lieux.yml` (14 cas : lieu géré
par personne / par MIN / par la Coop × flux présent, absent, plus ou moins
frais). On teste le fonctionnement, pas la forme du SQL.

| Sous-assertion | Module | Preuve |
|---|---|---|
| déréférencement nocturne restreint aux lignes externes (`GARDE_LIGNE_EXTERNE`) | `etl/load/carto_integration_lieux.py` | 🧪 TI-manuel `cas_cycle_de_vie_lieux.yml` (`min_absent`, `coop_absent`, `min_cree_sans_reference` vs `externe_absent`) |
| réactivation restreinte de même, jamais sur un lieu supprimé | idem | 🧪 idem (`min_masque_present`, `min_supprime_present`, `coop_masque_present` vs `externe_masque_present`) |
| les données suivent la fraîcheur, pas l'outil : une ligne MIN reçoit encore le flux plus frais, une ligne coop jamais | idem | 🧪 idem (`min_masque_present` → nom du flux ; `min_present_moins_frais` → nom initial ; `coop_*` → nom initial) |
| le DAG exécute bien ce module | `carto-dag-import.py` | 📄 (18/09/2026, `sql_integration_lieux("{{ run_id }}")`) — le job CI `test-dag` charge le DAG ; ❌ pas d'assertion DAG ↔ module |

### L-07 « Opendata : filtre V145, 23 lieux masqués encore publiés »

| Sous-assertion | Module | Preuve |
|---|---|---|
| le filtre actuel (`carto_id OU visible`) et son trou | V145 | 📄 + 🔎 requête de comptage (23, mesuré 17/09) — la **correction** est le reliquat #1943 ; le test viendra avec elle |

### L-08 « Délai carte ~5 h (cache du front, hard refresh par carto-dag) »

| Sous-assertion | Module | Preuve |
|---|---|---|
| le front carte recharge par cycles | système externe | 📄 constat d'exploitation — **non prouvable de notre côté** ; assumé comme tel dans le doc |

### L-09 « Fraîcheur mednum : pas d'expiration globale, mergeOldLieux 6 mois »

| Sous-assertion | Module | Preuve |
|---|---|---|
| comportement de la mednum (fichier national) | système externe (mednum-cli) | 📄 exploration par agent (sept. 2026), docstring `carto-dag-import.py` — invérifiable en continu |

---

### L-10 « MIN écrit les lieux non coop (données + état) ; lieux coop en lecture seule dans MIN »

| Sous-assertion | Module | Preuve |
|---|---|---|
| `edited_by='min'`, `updated_at_min` à chaque écriture, jamais `updated_at` (généré) | MIN `PrismaLieuInclusionRepository.ts` | 🤝 MIN — test base réelle `PrismaLieuInclusionRepository.test.ts` (PR MIN #1953, CI GitHub bloquante) |
| `source='Mon Inclusion Numérique'` sur les écritures de données seulement (jamais suppression ni visibilité) | MIN | 🤝 MIN — idem (3 cas : donnée signée, visibilité et suppression sans `source`) |
| lieux coop refusés côté serveur (8 actions via `verifierDroitsLieu`) et masqués côté UI, message vers la Coop | MIN | 🤝 MIN — `verifierDroitsLieu.test.ts`, tests d'actions, `LieuInclusionDetails.test.tsx`, `ListeLieuxInclusion.test.tsx` (PR #1953) |
| une écriture MIN (`updated_at_min`) sort la ligne du cycle de vie carto | dataspace | 🧪 L-06 |

## P — Les personnes

### P-01 « Un identifiant unique par source, clés du rapprochement »

| Sous-assertion | Module | Preuve |
|---|---|---|
| contraintes UNIQUE sur les 4 identifiants | V004 | 📄 catalogue — ❌ TI trivial à créer (double insert → erreur) |
| AC apparie par `aidant_connect_id`, id-poste par `cn_pg_id` | DAGs | 📄 — TU partiels : `tests-unitaires/ac/`, `tests-unitaires/idposte/` couvrent le *transform*, pas l'upsert |
| la coop rattache par email (3 chemins) | coop `ensurePersonneMain.ts` | 🤝 — aucune preuve chez nous |

### P-02 « Visibilité carte d'une personne : expose = lieu_actif ∧ compte_coop_actif ∧ visible_coop ∧ emploi_autorise ; adresse publiée = COALESCE(coop.users.email, mail_pro) »

**C'est l'assertion la mieux prouvée du système** : spécification exécutable
`tests/carto/cas_visibilite.yml` (25 cas) + `tests/carto/test_visibilite_api_carto.py`
(insertion en transaction, interrogation d'`api.carto`, rollback).
Dernière exécution : 2026-09-22, 37 passed / 2 skipped / 2 xfailed.

| Sous-assertion | Cas de la spec | Statut |
|---|---|---|
| CN en poste (coop ou idposte) → visible | `cn_emploi_coop`, `cn_emploi_idposte` | 🧪 TI-manuel |
| CN sans emploi actif → exclu (`cn_sans_emploi_actif`) | `cn_sans_emploi_actif` | 🧪 |
| lieu terminé / supprimé → exclu | `cn_lieu_termine`, `cn_lieu_supprime`, `mediateur_lieu_supprime` | 🧪 |
| masqué (is_visible=false) → exclu | `cn_masque`, `mediateur_masque` | 🧪 |
| compte coop supprimé → exclu | `cn_compte_supprime` | 🧪 |
| lieu masqué carto / sans carto_id → personne invisible | `cn_lieu_masque_carto`, `cn_lieu_sans_id_carto` | 🧪 |
| aidant AC admis d'office ; AC inactif → médiateur simple | `ac_actif`, `ac_inactif_devient_mediateur` | 🧪 |
| **sans compte Coop → jamais visible** (P-07 du doc) | `ac_sans_compte_coop` | 🧪 |
| médiateur déclaratif admis sans contrôle d'emploi | `mediateur_simple`, `mediateur_emploi_inactif_reste_visible` | 🧪 |
| **`deleted_at` n'exclut PAS** — marqueur par source, jamais effacé (V171) | `personne_deleted_at_reste_visible`, `cn_deleted_at_avec_emploi_actif` | 🧪 |
| `mail_perso` n'alimente jamais l'adresse publiée (V170) | `adresse_mail_perso_non_publiee` | 🧪 |
| repli sur `mail_pro` conservé | `adresse_mail_pro_publiee` | 🧪 |
| **manques connus documentés en xfail** : CN à contrat rompu, structure AC supprimée, médiateur dormant | `manque_cn_contrat_rompu`, `manque_ac_structure_supprimee`, `manque_mediateur_dormant` | 🧪 xfail — la spec encode le manque, pas seulement la règle |

⚠️ Non couvert : **distinguer une personne réellement partie**. `deleted_at` ne
sert pas (V171, cf. § 3.5 du doc technique) ; il faudrait l'absence d'emploi
actif toutes sources confondues, et un arbitrage métier. ❌ — encodé en `manque`
(`manque_personne_reellement_partie`, skip).

⚠️ Non couvert : le cas où **la même adresse est enregistrée des deux côtés**
(compte Coop *et* `mail_perso` du dossier CN). Elle reste alors publiée, le
filtre portant sur le champ d'origine et non sur la valeur. ❌ — aucun test, et
aucune règle décidée ; population mesurable via
`scripts/rapport_exposition_carto.sql` (R4/R5).

→ Seule faiblesse : **tout ça est hors CI** (A-01).

### P-03 « Trois notions d'activité non alignées ; seul le contrat pilote l'affectation idposte »

| Sous-assertion | Module | Preuve |
|---|---|---|
| `est_active` idposte recalculée depuis `date_rupture` | `schema-idPoste.py` | 📄 — ❌ TU à créer |
| une source n'éteint pas l'affectation d'une autre | modèle (upsert par `(personne, sa, source)`) | 📄 clé composite — le manque résultant (CN rompu visible) est prouvé en xfail (`manque_cn_contrat_rompu`) |
| affectations lieu = vue temps réel coop | V151 | 📄 + indirectement 🧪 (toute la spec carto passe par elle) |

### P-04 « MIN : entrée par `est_actuellement_*_en_poste`, `deleted_at` ignoré »

| Sous-assertion | Module | Preuve |
|---|---|---|
| définition des flags | V092 | 📄 — ❌ TI à créer (personne + affectations → flags attendus) |
| loaders MIN : conditions d'entrée, filtre « anciens » | `PrismaListeAidantsMediateursLoader.ts` | 📄 (des tests vitest existent sur les presenters/use-cases doublons ; **pas sur ce loader**) — ❌ à créer côté MIN |
| `deleted_at` ignoré (sauf loader doublons) | MIN | 📄 constat 16/09/2026 — c'est un **bug documenté** (piège n° 3) : le test viendra avec la correction |

### P-05 « Fusion automatique sous gardes strictes, journalisée »

| Sous-assertion | Module | Preuve |
|---|---|---|
| les 4 gardes (nom normalisé, même SA, pas de chevauchement, non ambigu) | `personne-reconciliation-dag.py` | 📄 — ❌ TU à créer (la logique est en SQL inline) |
| journalisation systématique | idem | 🔎 `audit.personne_merge_log` (winner/loser/moved_identifiers) |
| aucune fusion des supprimées | CTE de base | 📄 |

---

## C — Les coordonnées

### C-01 « La carte lit email/téléphone EN DIRECT sur le compte coop, repli idposte »

| Sous-assertion | Module | Preuve |
|---|---|---|
| chaîne COALESCE email (coop.users → mail_pro), `mail_perso` exclu | V170 | 🧪 `adresse_mail_perso_non_publiee`, `adresse_mail_pro_publiee` |
| adresse identique côté Coop et `mail_perso` → publiée quand même | V170 | ❌ aucun test, aucune règle décidée (cf. P-02) |
| chaîne COALESCE téléphone (coop.users → idposte) | V164/V165 | 📄 SQL des vues — ❌ cas à ajouter à la spec carto (téléphone attendu par cas) |
| normalisation E.164 | `main.normaliser_telephone` (V164) | ❌ TU/TI à créer (fonction pure SQL — testable trivialement) |
| personne masquée → aucune coordonnée exposée | V165 | 🧪 via `cn_masque`/`mediateur_masque` (la ligne entière disparaît) |

### C-02 « `contact->'coop'` et `is_visible` de main.personne : copies gelées »

| Sous-assertion | Module | Preuve |
|---|---|---|
| plus aucun écrivain sur ces colonnes | V164 (docstring) + DAGs | 📄 — 🔎 sonde possible à créer : `max` des fraîcheurs de ces clés doit rester figé (→ A-03) |
| MIN et dataviz lisent encore la copie gelée | MIN + V163 | 📄 — bug documenté (piège n° 9), test avec la correction |

### C-03 « Opendata ne publie aucune coordonnée personnelle »

| Sous-assertion | Module | Preuve |
|---|---|---|
| les vues opendata n'exposent que le contact du lieu | migrations opendata | 📄 — ❌ **TI à créer, le plus important de la famille C** : aucune colonne des vues `opendata.*` ne doit joindre `main.personne.contact` ni `coop.users` (test de non-régression RGPD) |

---

## Récapitulatif des trous (❌) — candidats de tests

Par rentabilité décroissante :

- **A-01 — Brancher `tests/carto/` et `tests/coop/` en CI** (les specs de
  visibilité, 25 cas, et de cycle de vie, 14 cas, plus le filet, sont nos
  meilleures preuves et ne protègent rien tant qu'elles sont manuelles ; le job
  `test_migration` a déjà une PostGIS neuve — y ajouter migrations + schéma
  coop minimal + specs).
- ~~A-02~~ — **réalisé le 18/09/2026** (SEPT #1950) : balayage des orphelins
  dans le filet (`SQL_RETIRER_ORPHELINS`), contrôle de santé §7,
  `tests/coop/test_filet_registre_lieux.py`.
- **A-03 — TI de non-régression RGPD opendata** (C-03) + sonde « copies gelées » (C-02).
- **A-06 — Reconnaître une personne réellement partie** (P-02) : besoin réel,
  signal manquant. `deleted_at` a été essayé (V170) et retiré le jour même
  (V171) : c'est un marqueur par source, non effacé, porté par 154 personnes
  toutes en poste. Piste : absence d'emploi actif toutes sources confondues —
  arbitrage métier d'abord.
- **A-05 — Adresse personnelle enregistrée des deux côtés** (P-02, C-01) : le
  filtre V170 porte sur le champ d'origine, pas sur la valeur. Une adresse
  saisie à la fois sur le compte Coop et comme `mail_perso` reste publiée.
  Population mesurable (`scripts/rapport_exposition_carto.sql`, R4/R5) ; aucune
  règle décidée à ce jour — c'est un arbitrage métier avant d'être un test.
- **A-04 — TU des SQL inline** aujourd'hui invérifiables : garde de fraîcheur AC
  (T-02), COALESCE id-poste (T-03), gardes de fusion (P-05). L-06 a été
  traitée autrement le 18/09/2026 : SQL extrait en module et **exécuté tel
  quel sur base** par une spécification (`tests/carto/cas_cycle_de_vie_lieux.yml`)
  — tester le fonctionnement plutôt que la forme ; méthode à préférer pour
  les suivants.
- **A-05 — TI colonne générée** (T-01), unicité des identifiants (P-01),
  `normaliser_telephone` (C-01), équivalence `[]`/NULL en divergences (L-04),
  idempotence du filet (T-05), flags V092 (P-04).
- **Côté coop (🤝, à faire acker)** : preuves de la double écriture (L-01), du
  difftool (T-04), du rattachement par email (P-01).

---

*Document généré le 17/09/2026 (inventaire initial). Statuts 📄 datés du jour.
À re-balayer à chaque évolution des docs narratifs (règle du préambule : les
documents vivent ensemble).*
