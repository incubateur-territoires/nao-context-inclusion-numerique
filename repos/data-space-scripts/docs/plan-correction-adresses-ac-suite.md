# Plan — correction des adresses AC (suite)

> État au 2026-06-03. Fait le lien entre le fix d'ingestion (livré), le backfill
> de l'existant (Option A), et la refonte de l'invariant SIRENE (Option B).

## Déjà livré (branche `audit/adresse-canonique-sirene`)
- `1c114be` — **fix DAG** : géocodage AC sur le `code_postal` (plus sur le
  `code_insee` source pollué). Agit sur les **prochains** traitements.
- `3b0f742` — entrées changelog.
- `acc1ccd` — brief d'ingestion + **outil de plan backfill** (dry-run).
- Diagnostic, ticket #1534, CSV d'incohérences pour AC.

## Option A — rattraper l'existant (re-géocoder la source sur CP)

Re-jouer le géocodage corrigé sur les canoniques AC déjà en base. **N'utilise
pas SIRENE.** Dry-run validé : **550 déplacements / 2 709**, 0 échec, déchets
outre-mer corrigés (ex. Nouméa→Bitche).

### A.1 — Finir l'outil (dev)
`scripts/backfill_geocodage_ac_cp.py` : implémenter `--apply` (aujourd'hui stub) :
- Cibler les **550 `DEPLACE`** (commune change) ; laisser les `INCHANGE`.
- Adresse **exclusive** → UPDATE en place ; adresse **partagée** (13) → INSERT
  nouvelle `main.adresse` + repointage `adresse_id` (ne jamais muter une adresse
  partagée).
- **Journal avant/après** dans `audit.backfill_geocodage_ac` (réversible).
- Transaction ; dry-run par défaut ; sur `dataspace_dev` d'abord.
- Valider : relancer `verifier_adresse_canonique_sirene.py` → la part AC
  `COMMUNE_DIFFERENTE` doit s'effondrer.

### A.2 — Appliquer en PROD (⚠ pas via ce script)
**Pré-requis** : la branche `audit/adresse-canonique-sirene` doit d'abord être
**mergée sur `main`** (MR `glab`) — le fix DAG n'est PAS encore déployé (deploy
au merge sur `main`).
Ensuite, le bon véhicule = le **DAG corrigé**, re-joué en **forçant le
re-traitement complet**. Le script de A.1 sert à dev/preview, pas à muter la prod.
- Mécanisme : `cutoff_date` du DAG est codé en dur à `now − 4 mois`
  (`aidants-connect-dag.py:447`). Deux options :
  - **Laisser faire** : tout le parc se re-géocode tout seul en ≤ 4 mois (le
    cycle incrémental repasse chaque structure). Zéro intervention.
  - **Forcer** : ajouter un `Param("force_full_refresh", bool)` qui met
    `cutoff_date = pendulum.now().date()` quand vrai → un run re-traite tout.
- Pré-requis prod : Variable Airflow **`API_SIRENE_TOKEN` valide** (celle du
  `.env` dev est expirée — 401), car l'enrichissement complet repasse aussi par
  SIRENE.

## Option B — invariant « canonique = adresse SIRENE » (à challenger)

But : garantir qu'une canonique porte l'adresse **déclarée au SIRET** (SIRENE).
Différent de A (qui place au **site opérationnel** de la source).

### ⚠ Assertion à remettre en cause (doute légitime)
**« Même commune ⇒ c'est l'adresse SIRENE » est FAUX.** `MEME_COMMUNE_LOIN`
signifie seulement que le point stocké et le point SIRENE tombent dans la même
commune — pas qu'ils sont à la **même adresse** (ils peuvent être à plusieurs km).
Conséquences :
- Les statuts du vérificateur (`MEME_COMMUNE_LOIN`, etc.) sont des **diagnostics
  de distance**, pas des garanties de conformité.
- Seul **`OK_BAN_IDENTIQUE`** prouve « déjà à l'adresse SIRENE » ; `OK_PROCHE`
  (<200 m) = « quasiment ». Tout le reste **n'est pas** à l'adresse SIRENE.
- Donc B ne peut pas « sauter les déjà-bons par commune » : il doit **écrire
  explicitement l'adresse SIRENE** (re-géocoder SIRENE → repointer) partout où
  ce n'est pas `OK_BAN_IDENTIQUE`.

### Tension A ↔ B à trancher (surtout les ~128 multi-sites)
- A place la structure à son **site réel** (adresse opérationnelle source).
- B la place à l'**adresse déclarée au SIRET** (siège SIRENE).
- Pour un mono-site, A ≈ B (même commune, même adresse à la précision BAN près).
- Pour un multi-site (France Services à X, siège SIRET à Y), A et B **divergent**
  → c'est là qu'il faut décider : adresse opérationnelle (et marquer antenne ?)
  vs adresse de siège.
- Limite supplémentaire de B : l'« adresse SIRENE » qu'on écrit est elle-même
  une **re-géocodage BAN** (imprécision propre). B ne donne pas une vérité
  parfaite, juste l'adresse de l'établissement déclaré.

### Question ouverte pour la phase B
Quelle est l'adresse « canonique » voulue : **opérationnelle** (A) ou **déclarée
au SIRET** (B) ? La réponse conditionne tout le reste (et le sens du champ
`denomination_antenne`).

## Séquence
1. A.1 (dev) → 2. A.2 (prod, via DAG) → 3. trancher A vs B → 4. concevoir B.
