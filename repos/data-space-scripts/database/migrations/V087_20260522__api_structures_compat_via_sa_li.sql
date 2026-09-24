-- ============================================================
-- V087 – Refonte phase 5.1 : api.structures bascule vers SA + LI (vue de compat)
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md phase 5.1 et phase 6 (DROP main.structure).
-- L'API publique /structures (consommée par postgrest_anct_dev) doit continuer
-- à servir un payload structurellement équivalent au legacy pendant que MIN et
-- coop migrent leurs consommateurs.
--
-- STRATÉGIE : "vue de compat" (option 2 retenue le 2026-05-22) qui combine
-- les 2 nouveaux concepts :
--   - structure_administrative (entité légale = SIRET)
--   - lieu_inclusion (lieu géographique)
-- avec une jointure via lieu_inclusion_structure_administrative.
--
-- Couverture des cas :
--   1) SA avec asso (mixtes) : 1 ligne par couple (SA, LI). Le nom et
--      l'adresse viennent du LI ; les attributs SIRENE (SIRET, denom, code APE,
--      etat, categorie_juridique, RNA) viennent de SA. La SA peut avoir N
--      lieux d'inclusion → N lignes pour le même SIRET (= comportement
--      legacy quand N main.structure partageaient un SIRET).
--   2) SA sans asso (pures employeuses) : 1 ligne. Le nom = denomination_sirene
--      (compromis car SA n'a pas de colonne nom). L'adresse vient de SA.
--   3) LI sans asso (purs lieux d'inclusion) : 1 ligne. siret/rna/etc. = NULL
--      (comportement legacy : un lieu sans SIRET avait ces colonnes à NULL).
--
-- Comptages dataspace_dev 2026-05-22 :
--   - 28 651 lignes legacy → 26 163 attendues (1 585 mixtes + 6 331 SA pures
--     + 18 247 LI pures). L'écart de ~2 500 correspond aux doublons SIRET
--     dans main.structure absorbés par fusion SA — effet désiré de la refonte.
--
-- LIMITES (à investiguer, cf docs/refonte-structure-plan.md N7) :
--   - Le comportement bit-à-bit n'est PAS identique au legacy. Comptages,
--     ordre des lignes et nullité des champs SIRENE pour les purs lieux ont
--     changé.
--   - On n'a pas identifié exhaustivement les consommateurs de api.structures.
--     postgrest_anct_dev a SELECT, mais on ignore quels usages côté Coop /
--     ANCT s'appuient sur ce payload.
--   - À sonder avant phase 6 (DROP main.structure).
-- ============================================================

-- Vérifié 2026-05-22 : aucune vue ne dépend de api.structures (pas de
-- CASCADE nécessaire). DROP + CREATE permet d'adapter les types des colonnes
-- (la branche 3 doit pouvoir retourner NULL pour les colonnes SIRENE).
DROP VIEW IF EXISTS api.structures;
CREATE VIEW api.structures AS (
  -- 1) Cas mixtes : SA avec au moins 1 lieu_inclusion associé
  SELECT
    sa.siret,
    sa.rna,
    li.nom,
    sa.code_activite_principale,
    sa.etat_administratif,
    sa.denomination_sirene,
    sa.categorie_juridique AS code_categorie_juridique,
    cj.nom AS libelle_categorie_juridique,
    a.code_ban,
    a.numero_voie,
    a.nom_voie,
    a.repetition,
    a.code_postal,
    a.nom_commune,
    a.code_insee,
    concat_ws(' ', a.numero_voie, a.repetition, a.nom_voie, a.code_postal, a.nom_commune) AS adresse,
    st_x(a.geom) AS longitude,
    st_y(a.geom) AS latitude
  FROM main.structure_administrative sa
  JOIN main.lieu_inclusion_structure_administrative asso ON asso.structure_administrative_id = sa.id
  JOIN main.lieu_inclusion li ON li.id = asso.lieu_id
  LEFT JOIN main.adresse a ON a.id = COALESCE(li.adresse_id, sa.adresse_id)
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text

  UNION ALL

  -- 2) SA sans asso (pures employeuses) : nom = denomination_sirene
  SELECT
    sa.siret,
    sa.rna,
    sa.denomination_sirene AS nom,
    sa.code_activite_principale,
    sa.etat_administratif,
    sa.denomination_sirene,
    sa.categorie_juridique AS code_categorie_juridique,
    cj.nom AS libelle_categorie_juridique,
    a.code_ban,
    a.numero_voie,
    a.nom_voie,
    a.repetition,
    a.code_postal,
    a.nom_commune,
    a.code_insee,
    concat_ws(' ', a.numero_voie, a.repetition, a.nom_voie, a.code_postal, a.nom_commune) AS adresse,
    st_x(a.geom) AS longitude,
    st_y(a.geom) AS latitude
  FROM main.structure_administrative sa
  LEFT JOIN main.adresse a ON a.id = sa.adresse_id
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  WHERE NOT EXISTS (
    SELECT 1 FROM main.lieu_inclusion_structure_administrative asso
    WHERE asso.structure_administrative_id = sa.id
  )

  UNION ALL

  -- 3) LI sans asso (purs lieux d'inclusion) : siret/rna/SIRENE = NULL
  SELECT
    NULL::varchar AS siret,
    NULL::varchar AS rna,
    li.nom,
    NULL::varchar AS code_activite_principale,
    NULL::varchar AS etat_administratif,
    NULL::varchar AS denomination_sirene,
    NULL::varchar AS code_categorie_juridique,
    NULL::varchar AS libelle_categorie_juridique,
    a.code_ban,
    a.numero_voie,
    a.nom_voie,
    a.repetition,
    a.code_postal,
    a.nom_commune,
    a.code_insee,
    concat_ws(' ', a.numero_voie, a.repetition, a.nom_voie, a.code_postal, a.nom_commune) AS adresse,
    st_x(a.geom) AS longitude,
    st_y(a.geom) AS latitude
  FROM main.lieu_inclusion li
  LEFT JOIN main.adresse a ON a.id = li.adresse_id
  WHERE NOT EXISTS (
    SELECT 1 FROM main.lieu_inclusion_structure_administrative asso
    WHERE asso.lieu_id = li.id
  )
);

COMMENT ON VIEW api.structures IS
  'Vue de compatibilité — combine structure_administrative + lieu_inclusion via '
  'la table d''association. Refonte phase 5.1 (V087). Comportement non strictement '
  'identique au legacy (déduplication par SIRET). À sonder avant DROP main.structure.';

-- GRANT à conserver (postgrest_anct_dev consomme cette API)
GRANT SELECT ON TABLE api.structures TO postgrest_anct_dev;

NOTIFY pgrst, 'reload schema';
