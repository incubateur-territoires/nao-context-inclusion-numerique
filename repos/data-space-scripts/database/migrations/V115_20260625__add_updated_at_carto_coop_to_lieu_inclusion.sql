-- Fraîcheur métier par source sur lieu_inclusion — ÉTAPE 1/2.
--
-- Ajoute les colonnes updated_at_carto / updated_at_coop / updated_at_min et
-- SEED leurs valeurs historiques. La bascule de `updated_at` en colonne
-- calculée (GENERATED) se fait en V116, APRÈS DROP des vues qui en dépendent
-- (api.carto, dataviz.structures) — d'où le découpage en deux migrations.
--
-- `updated_at` (legacy) est conservé tel quel ici : il sert de PLANCHER au seed
-- pour les lieux que la couche source ne permet pas de reconstituer.

-- 1) Colonnes par source
ALTER TABLE main.lieu_inclusion
    ADD COLUMN updated_at_carto TIMESTAMP WITHOUT TIME ZONE,
    ADD COLUMN updated_at_coop  TIMESTAMP WITHOUT TIME ZONE,
    ADD COLUMN updated_at_min   TIMESTAMP WITHOUT TIME ZONE;

COMMENT ON COLUMN main.lieu_inclusion.updated_at_carto IS
    'Date du dernier changement métier réel détecté par carto-dag.';
COMMENT ON COLUMN main.lieu_inclusion.updated_at_coop IS
    'Date du dernier changement métier réel détecté par coop-dag.';
COMMENT ON COLUMN main.lieu_inclusion.updated_at_min IS
    'Date du dernier changement métier réel effectué via l''application MIN.';

-- 2) SEED des valeurs historiques.
-- Le trigger `updated_at` (BEFORE UPDATE) bumperait `updated_at` à now() à chaque
-- UPDATE ci-dessous (NEW IS DISTINCT FROM OLD) et corromprait le plancher lu en 2b.
-- On le désactive le temps du seed.
ALTER TABLE main.lieu_inclusion DISABLE TRIGGER updated_at;

-- 2a) Rejeu de la couche source (captures FULL depuis V099, en prod ~depuis le
--     2026-06-08). carto-dag et coop-dag capturent l'intégralité des structures à
--     chaque run (cf write_to_source_*), donc chaque lieu apparaît dans chaque
--     capture : la comparaison payload N vs N-1 détecte un vrai changement métier.
--     On NE compte PAS la première capture (prev IS NULL) comme un changement,
--     sinon tout lieu stable se verrait coller la date de début de capture.
WITH carto_changes AS (
    SELECT carto_id, MAX(ingested_at) AS last_change
    FROM (
        SELECT donnee ->> 'id' AS carto_id,
               ingested_at,
               donnee,
               LAG(donnee) OVER (
                   PARTITION BY donnee ->> 'id'
                   ORDER BY ingested_at
               ) AS prev
        FROM source.carto__structures
    ) s
    WHERE prev IS NOT NULL
      AND donnee IS DISTINCT FROM prev
    GROUP BY carto_id
)
UPDATE main.lieu_inclusion l
SET updated_at_carto = c.last_change
FROM carto_changes c
WHERE l.structure_cartographie_nationale_id IS NOT NULL
  AND l.structure_cartographie_nationale_id::text = c.carto_id;

WITH coop_changes AS (
    SELECT coop_id, MAX(ingested_at) AS last_change
    FROM (
        SELECT donnee ->> 'structure_coop_id' AS coop_id,
               ingested_at,
               donnee,
               LAG(donnee) OVER (
                   PARTITION BY donnee ->> 'structure_coop_id'
                   ORDER BY ingested_at
               ) AS prev
        FROM source.coop__structures
    ) s
    WHERE prev IS NOT NULL
      AND donnee IS DISTINCT FROM prev
    GROUP BY coop_id
)
UPDATE main.lieu_inclusion l
SET updated_at_coop = c.last_change
FROM coop_changes c
WHERE l.structure_coop_id IS NOT NULL
  AND l.structure_coop_id::text = c.coop_id;

-- 2b) Plancher pour la traîne sans signal de rejeu (lieux non modifiés depuis le
--     début de la capture, ou antérieurs à celle-ci) : on retombe sur l'ancien
--     `updated_at` (sinon `created_at`), attribué à une colonne source réellement
--     présente sur le lieu, pour ne pas faire régresser `date_maj`.
UPDATE main.lieu_inclusion
SET updated_at_carto = COALESCE(updated_at, created_at)
WHERE updated_at_carto IS NULL
  AND updated_at_coop IS NULL
  AND structure_cartographie_nationale_id IS NOT NULL;

UPDATE main.lieu_inclusion
SET updated_at_coop = COALESCE(updated_at, created_at)
WHERE updated_at_carto IS NULL
  AND updated_at_coop IS NULL
  AND structure_cartographie_nationale_id IS NULL
  AND structure_coop_id IS NOT NULL;

UPDATE main.lieu_inclusion
SET updated_at_min = COALESCE(updated_at, created_at)
WHERE updated_at_carto IS NULL
  AND updated_at_coop IS NULL
  AND updated_at_min IS NULL
  AND structure_cartographie_nationale_id IS NULL
  AND structure_coop_id IS NULL;

ALTER TABLE main.lieu_inclusion ENABLE TRIGGER updated_at;

-- 3) Helper de comparaison de tableaux TEXT[] indépendamment de l'ordre des éléments.
--
-- Contexte : carto-dag et coop-dag détectent un "changement métier réel" via
-- `l.<col> IS DISTINCT FROM <source>` pour décider de bumper updated_at_carto/coop.
-- Or PostgreSQL compare les arrays par position : '{a,b}' IS DISTINCT FROM '{b,a}'
-- = TRUE. La source (string_to_array / API coop) peut réordonner un array sans
-- changement réel de contenu → faux bump de fraîcheur. On compare donc les
-- versions triées.
--
-- Ne PAS trier à l'écriture : la valeur stockée garde son ordre d'origine
-- (un tri à l'écriture réécrirait en masse les arrays et déclencherait justement
-- le faux changement qu'on cherche à éviter, en plus de modifier l'ordre exposé
-- aux utilisateurs via api.carto / dataviz).

CREATE OR REPLACE FUNCTION main.sorted_text_array(arr text[])
RETURNS text[]
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    -- COALESCE sur l'entrée : préserve la distinction tableau vide '{}' vs NULL
    -- (unnest('{}') ne produit aucune ligne → array_agg renvoie NULL).
    SELECT COALESCE(
        (SELECT array_agg(elem ORDER BY elem) FROM unnest(arr) AS elem),
        arr
    );
$$;

COMMENT ON FUNCTION main.sorted_text_array(text[]) IS
    'Renvoie le tableau trié (ordre lexical) pour comparer des TEXT[] indépendamment '
    'de l''ordre des éléments. Préserve NULL et tableau vide. Utilisé par carto-dag / '
    'coop-dag pour ne pas détecter un faux changement métier lors d''un simple '
    'réordonnancement (seule la comparaison est triée, pas la valeur stockée).';
