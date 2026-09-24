-- ============================================================
-- V094 – Refonte phase 5.5 : bascule des vues dataviz vers SA + LI
-- ============================================================
-- CONTEXTE :
-- Cf docs/refonte-structure-plan.md §N7. Les 8 vues dataviz consommees par
-- Metabase lisaient encore main.structure (legacy) et/ou
-- main.personne_affectations (legacy). Depuis la refonte phase 5.1-5.4
-- (V087/V088/V089/V092), les tables sources de verite sont :
--   - main.structure_administrative (SA) : SIRENE/categorie/etat/IDs sources
--   - main.lieu_inclusion (LI)           : nom/typologies/services/horaires
--                                          /presentation/mediateurs/etc.
--   - main.personne_affectations_emploi  : ex pa.type='structure_emploi'
--   - main.personne_affectations_lieu    : ex pa.type='lieu_activite'
--
-- BASCULE :
--   - dataviz.structures           : UNION ALL 3 cas (mixte / SA pure / LI pure)
--   - dataviz.poste                : structure_administrative (FK migree V078)
--   - dataviz.poste_pseudonymisee  : SELECT projection sur poste (PII filtrees)
--   - dataviz.lieux_inclusion_numerique : LI + paf_lieu
--   - dataviz.personne             : SA via paf_emploi + LI via paf_lieu
--   - dataviz.personne_pseudonymisee : idem (PII filtrees)
--   - dataviz.structures_employeuses : SA + paf_emploi + activites_coop (via LI)
--   - dataviz.zonages              : LI + paf_lieu (cote lieu d'activite)
--   - dataviz.personnes_accompagnements : LI (fix : activites_coop.lieu_id pointe
--                                          deja sur LI depuis V084)
--
-- IMPORTANT — denomination_antenne :
--   Le pattern "grand reseau" (Emmaus Connect, Reconnect, etc.) introduit
--   en 2026-05-25 conserve les antennes via la colonne SA.denomination_antenne.
--   Toutes les vues qui exposent un "nom de structure" utilisent :
--     COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom_structure
--
-- NEXT STEP : sonder les dashboards Metabase en prod
--   Cette refonte conserve le **contrat de colonnes** des 9 vues (memes
--   noms, memes types). Le comportement (volumes, IDs, ordre) PEUT changer
--   marginalement. Apres deploiement, lister les dashboards Metabase qui
--   consomment chaque vue et verifier visuellement qu'ils tournent toujours.
-- ============================================================

-- Ordre du DROP : poste_pseudonymisee depend de poste (cf dependances).
DROP VIEW IF EXISTS dataviz.poste_pseudonymisee;
DROP VIEW IF EXISTS dataviz.poste;
DROP VIEW IF EXISTS dataviz.structures;
DROP VIEW IF EXISTS dataviz.lieux_inclusion_numerique;
DROP VIEW IF EXISTS dataviz.personne;
DROP VIEW IF EXISTS dataviz.personne_pseudonymisee;
DROP VIEW IF EXISTS dataviz.structures_employeuses;
DROP VIEW IF EXISTS dataviz.zonages;
DROP VIEW IF EXISTS dataviz.personnes_accompagnements;

-- ============================================================
-- 1) dataviz.structures
-- ============================================================
-- Pattern UNION ALL 3 cas, calque sur V087 (api.structures) + colonnes
-- specifiques au schema dataviz (toutes les colonnes "metier" de l'ancien
-- main.structure, plus les colonnes derivees adresse/coll_terr/zonage).
CREATE VIEW dataviz.structures AS (
  -- Cas 1 : SA mixte avec asso → 1 ligne par couple (SA, LI)
  SELECT
    sa.id,
    li.structure_coop_id,
    sa.structure_ac_id,
    sa.structure_tp_id,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom,
    sa.denomination_sirene,
    sa.siret,
    sa.rna,
    COALESCE(li.adresse_id, sa.adresse_id) AS adresse_id,
    li.contact,
    sa.etat_administratif,
    sa.code_activite_principale,
    sa.categorie_juridique,
    sa.nb_mandats_ac,
    sa.publique,
    li.structure_cartographie_nationale_id,
    li.visible_pour_cartographie_nationale,
    li.typologies,
    li.presentation_resume,
    li.presentation_detail,
    li.horaires,
    li.prise_rdv,
    li.services,
    li.publics_specifiquement_adresses,
    li.prise_en_charge_specifique,
    li.frais_a_charge,
    li.dispositif_programmes_nationaux,
    li.formations_labels,
    li.autres_formations_labels,
    li.itinerance,
    li.modalites_acces,
    li.modalites_accompagnement,
    li.mediateurs_en_activite,
    li.emplois,
    sa.last_sirene_enrich_at,
    sa.created_at,
    sa.updated_at,
    li.fiche_acces_libre,
    sa.edited_by,
    adresse.clef_interop AS addr_clef_interop,
    adresse.code_ban AS addr_code_ban,
    adresse.departement AS addr_departement,
    adresse.code_postal AS addr_code_postal,
    adresse.code_insee AS addr_code_insee,
    adresse.nom_commune AS addr_nom_commune,
    adresse.nom_voie AS addr_nom_voie,
    adresse.repetition AS addr_repetition,
    adresse.numero_voie AS addr_numero_voie,
    coll_terr.region_code AS coll_terr_region_code,
    coll_terr.region_nom AS coll_terr_region_nom,
    coll_terr.departement_code AS coll_terr_departement_code,
    coll_terr.departement_nom AS coll_terr_departement_nom,
    coll_terr.code_insee AS coll_terr_code_insee,
    coll_terr.commune_nom AS coll_terr_commune_nom,
    cj.nom AS categories_juridiques_nom,
    zonage.type AS zonage_type,
    zonage.code AS zonage_code,
    zonage.libelle AS zonage_libelle,
    zonage.commentaire AS zonage_complement,
    st_y(adresse.geom) AS addr_latitude,
    st_x(adresse.geom) AS addr_longitude
  FROM main.structure_administrative sa
  JOIN main.lieu_inclusion_structure_administrative asso ON asso.structure_administrative_id = sa.id
  JOIN main.lieu_inclusion li ON li.id = asso.lieu_id
  LEFT JOIN main.adresse adresse ON adresse.id = COALESCE(li.adresse_id, sa.adresse_id)
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))

  UNION ALL

  -- Cas 2 : SA pure (sans asso) → 1 ligne, champs metier NULL
  SELECT
    sa.id,
    NULL::uuid AS structure_coop_id,
    sa.structure_ac_id,
    sa.structure_tp_id,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom,
    sa.denomination_sirene,
    sa.siret,
    sa.rna,
    sa.adresse_id,
    NULL::jsonb AS contact,
    sa.etat_administratif,
    sa.code_activite_principale,
    sa.categorie_juridique,
    sa.nb_mandats_ac,
    sa.publique,
    NULL::varchar AS structure_cartographie_nationale_id,
    NULL::boolean AS visible_pour_cartographie_nationale,
    NULL::text[] AS typologies,
    NULL::text AS presentation_resume,
    NULL::text AS presentation_detail,
    NULL::varchar AS horaires,
    NULL::varchar AS prise_rdv,
    NULL::text[] AS services,
    NULL::text[] AS publics_specifiquement_adresses,
    NULL::text[] AS prise_en_charge_specifique,
    NULL::text[] AS frais_a_charge,
    NULL::text[] AS dispositif_programmes_nationaux,
    NULL::text[] AS formations_labels,
    NULL::text[] AS autres_formations_labels,
    NULL::text[] AS itinerance,
    NULL::text[] AS modalites_acces,
    NULL::text[] AS modalites_accompagnement,
    NULL::integer AS mediateurs_en_activite,
    NULL::integer AS emplois,
    sa.last_sirene_enrich_at,
    sa.created_at,
    sa.updated_at,
    NULL::varchar AS fiche_acces_libre,
    sa.edited_by,
    adresse.clef_interop AS addr_clef_interop,
    adresse.code_ban AS addr_code_ban,
    adresse.departement AS addr_departement,
    adresse.code_postal AS addr_code_postal,
    adresse.code_insee AS addr_code_insee,
    adresse.nom_commune AS addr_nom_commune,
    adresse.nom_voie AS addr_nom_voie,
    adresse.repetition AS addr_repetition,
    adresse.numero_voie AS addr_numero_voie,
    coll_terr.region_code AS coll_terr_region_code,
    coll_terr.region_nom AS coll_terr_region_nom,
    coll_terr.departement_code AS coll_terr_departement_code,
    coll_terr.departement_nom AS coll_terr_departement_nom,
    coll_terr.code_insee AS coll_terr_code_insee,
    coll_terr.commune_nom AS coll_terr_commune_nom,
    cj.nom AS categories_juridiques_nom,
    zonage.type AS zonage_type,
    zonage.code AS zonage_code,
    zonage.libelle AS zonage_libelle,
    zonage.commentaire AS zonage_complement,
    st_y(adresse.geom) AS addr_latitude,
    st_x(adresse.geom) AS addr_longitude
  FROM main.structure_administrative sa
  LEFT JOIN main.adresse adresse ON adresse.id = sa.adresse_id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))
  WHERE NOT EXISTS (
    SELECT 1 FROM main.lieu_inclusion_structure_administrative asso
    WHERE asso.structure_administrative_id = sa.id
  )

  UNION ALL

  -- Cas 3 : LI pure (sans asso) → 1 ligne, champs SIRENE NULL
  SELECT
    li.id,
    li.structure_coop_id,
    NULL::uuid AS structure_ac_id,
    NULL::integer AS structure_tp_id,
    li.nom,
    NULL::varchar AS denomination_sirene,
    NULL::varchar AS siret,
    NULL::varchar AS rna,
    li.adresse_id,
    li.contact,
    NULL::varchar AS etat_administratif,
    NULL::varchar AS code_activite_principale,
    NULL::varchar AS categorie_juridique,
    NULL::integer AS nb_mandats_ac,
    NULL::boolean AS publique,
    li.structure_cartographie_nationale_id,
    li.visible_pour_cartographie_nationale,
    li.typologies,
    li.presentation_resume,
    li.presentation_detail,
    li.horaires,
    li.prise_rdv,
    li.services,
    li.publics_specifiquement_adresses,
    li.prise_en_charge_specifique,
    li.frais_a_charge,
    li.dispositif_programmes_nationaux,
    li.formations_labels,
    li.autres_formations_labels,
    li.itinerance,
    li.modalites_acces,
    li.modalites_accompagnement,
    li.mediateurs_en_activite,
    li.emplois,
    NULL::date AS last_sirene_enrich_at,
    li.created_at,
    li.updated_at,
    li.fiche_acces_libre,
    li.edited_by,
    adresse.clef_interop AS addr_clef_interop,
    adresse.code_ban AS addr_code_ban,
    adresse.departement AS addr_departement,
    adresse.code_postal AS addr_code_postal,
    adresse.code_insee AS addr_code_insee,
    adresse.nom_commune AS addr_nom_commune,
    adresse.nom_voie AS addr_nom_voie,
    adresse.repetition AS addr_repetition,
    adresse.numero_voie AS addr_numero_voie,
    coll_terr.region_code AS coll_terr_region_code,
    coll_terr.region_nom AS coll_terr_region_nom,
    coll_terr.departement_code AS coll_terr_departement_code,
    coll_terr.departement_nom AS coll_terr_departement_nom,
    coll_terr.code_insee AS coll_terr_code_insee,
    coll_terr.commune_nom AS coll_terr_commune_nom,
    NULL::text AS categories_juridiques_nom,
    zonage.type AS zonage_type,
    zonage.code AS zonage_code,
    zonage.libelle AS zonage_libelle,
    zonage.commentaire AS zonage_complement,
    st_y(adresse.geom) AS addr_latitude,
    st_x(adresse.geom) AS addr_longitude
  FROM main.lieu_inclusion li
  LEFT JOIN main.adresse adresse ON adresse.id = li.adresse_id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))
  WHERE NOT EXISTS (
    SELECT 1 FROM main.lieu_inclusion_structure_administrative asso
    WHERE asso.lieu_id = li.id
  )
);

COMMENT ON VIEW dataviz.structures IS
  'Vue dataviz refondue phase 5.5 (V094). UNION ALL 3 cas SA+LI / SA pure / LI pure.';

-- ============================================================
-- 2) dataviz.poste
-- ============================================================
-- poste.structure_id pointe sur SA depuis V078. On remplace les references
-- main.structure par SA, en utilisant COALESCE(denomination_antenne,
-- denomination_sirene) comme "nom_structure" (champ exige par Metabase).
CREATE VIEW dataviz.poste AS (
  -- DGCL
  SELECT
    poste.poste_conum_id AS id_poste,
    sa.structure_tp_id AS id_structure,
    personne.cn_pg_id AS id_cn,
    poste.etat,
    poste.date_attribution,
    poste.date_rendu_poste AS date_rendu_de_poste,
    poste.typologie,
    poste.action_coselec,
    poste.origine_transfert,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom_structure,
    sa.siret,
    CASE WHEN sa.publique IS TRUE THEN 'Publique'::text ELSE 'Privée'::text END AS "publique/privée",
    cj.nom AS typologie_juridique,
    poste.etat_instruction_v1 AS "etat_de_l'instruction v1",
    poste.etat_instruction_v2 AS "etat_de_l'instruction v2",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "nom_du_département",
    coll_terr.departement_code AS "code_département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    coll_terr.code_insee,
    'DGCL'::text AS source_de_financement,
    subvention.date_debut_convention_dgcl AS "date_début/signature_convention",
    subvention.date_fin_convention_dgcl AS date_fin_convention,
    subvention.date_debut_financement_dgcl AS "date_début_financement",
    subvention.date_fin_financement_dgcl AS date_de_fin_financement,
    subvention.mois_utilises_periode_financement_dgcl AS "mois_consommés_sur_la_période_de_financement",
    NULL::smallint AS "mois_consommés_sur_le_poste",
    subvention.montant_subvention_v1 AS montant_subventions_hors_bonification,
    'Non'::text AS territoire_prioritaire,
    NULL::bigint AS "bonification découlant du lieu de permanence",
    subvention.montant_subvention_v1 AS montant_subventions_total,
    NULL::bigint AS "cp_à_date",
    CASE WHEN subvention.montant_subvention_v1 > 0
         THEN subvention.montant_versement_v1::numeric / subvention.montant_subvention_v1::numeric
         ELSE NULL::numeric END AS "cp_consommé",
    subvention.montant_subvention_v1 - subvention.montant_versement_v1 AS "reste_à_payer_convention",
    subvention.montant_avoir_v1 AS avoir,
    subvention.montant_versement_v1 AS montant_versement_1e_tranche,
    NULL::bigint AS montant_versement_2e_tranche,
    NULL::bigint AS montant_versement_3e_tranche,
    NULL::date AS date_versement_1e_tranche,
    NULL::date AS date_versement_2e_tranche,
    NULL::date AS date_versement_3e_tranche,
    personne.nom,
    personne.prenom AS "prénom",
    concat_ws(', ', (personne.contact -> 'coop') ->> 'email',
                   (personne.contact -> 'idposte') ->> 'mail_pro',
                   (personne.contact -> 'idposte') ->> 'mail_perso') AS emails,
    contrat.type AS type_ct,
    contrat.date_debut AS date_debut_contrat,
    contrat.date_fin AS date_fin_contrat,
    contrat.date_rupture,
    CASE WHEN contrat.date_rupture IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "rupture_anticipée",
    formation.lot,
    formation.marche_formation AS "marché_de_formation",
    formation.label AS formation,
    formation.date_debut AS "date_de_départ",
    formation.date_fin AS date_de_fin,
    formation.lieu,
    formation.parcours,
    formation.observations AS statut_formation_conum,
    NULL::text AS cra,
    CASE WHEN poste.poste_renouvele IS TRUE THEN 'Oui'::text
         WHEN poste.poste_renouvele IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "poste_renouvelé",
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure,
    contact_ref.nom::text AS "nom_référent_tp",
    contact_ref.prenom::text AS "prénom_référent_tp",
    contact_ref.telephone::text AS telephone,
    contact_ref.email::text AS mail_gestionnaire,
    NULL::text AS mail_2,
    NULL::text AS "référent_hiérarchique",
    CASE WHEN formation.pix IS TRUE THEN 'Oui'::text
         WHEN formation.pix IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS pix,
    CASE WHEN formation.remn IS TRUE THEN 'Oui'::text
         WHEN formation.remn IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS remn
  FROM main.structure_administrative sa
  LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
  LEFT JOIN admin.coll_terr ON coll_terr.code_insee::text = adresse.code_insee::text
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  JOIN main.poste ON sa.id = poste.structure_id
  LEFT JOIN main.personne ON poste.personne_id = personne.id
  LEFT JOIN main.formation ON personne.id = formation.personne_id
  LEFT JOIN main.contrat ON contrat.personne_id = personne.id
  LEFT JOIN main.subvention ON subvention.poste_id = poste.id
  LEFT JOIN LATERAL (
    SELECT c.nom, c.prenom, c.telephone, c.email
    FROM main.contact_structure_administrative cs
    JOIN main.contact c ON c.id = cs.contact_id
    WHERE cs.structure_administrative_id = sa.id
    ORDER BY c.id LIMIT 1
  ) contact_ref ON true
  WHERE subvention.montant_subvention_v1 IS NOT NULL

  UNION ALL

  -- DITP
  SELECT
    poste.poste_conum_id, sa.structure_tp_id, personne.cn_pg_id,
    poste.etat, poste.date_attribution, poste.date_rendu_poste,
    poste.typologie, poste.action_coselec, poste.origine_transfert,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene),
    sa.siret,
    CASE WHEN sa.publique IS TRUE THEN 'Publique'::text ELSE 'Privée'::text END,
    cj.nom,
    poste.etat_instruction_v1, poste.etat_instruction_v2,
    coll_terr.region_nom, coll_terr.departement_nom, coll_terr.departement_code,
    adresse.code_postal, coll_terr.commune_nom, coll_terr.code_insee,
    'DITP'::text,
    subvention.date_debut_convention_ditp, subvention.date_fin_convention_ditp,
    subvention.date_debut_financement_ditp, subvention.date_fin_financement_ditp,
    subvention.mois_utilises_periode_financement_ditp,
    NULL::smallint,
    subvention.montant_subvention_v2 - COALESCE(subvention.montant_bonification_v2, 0::bigint),
    CASE WHEN subvention.montant_bonification_v2 > 0 THEN 'Oui'::text ELSE 'Non'::text END,
    subvention.montant_bonification_v2,
    subvention.montant_subvention_v2,
    NULL::bigint,
    CASE WHEN subvention.montant_subvention_v2 > 0
         THEN (subvention.versement_1_v2 + COALESCE(subvention.versement_2_v2, 0::bigint) + COALESCE(subvention.versement_3_v2, 0::bigint))::numeric / subvention.montant_subvention_v2::numeric
         ELSE NULL::numeric END,
    subvention.montant_subvention_v2 - (COALESCE(subvention.versement_1_v2, 0::bigint) + COALESCE(subvention.versement_2_v2, 0::bigint) + COALESCE(subvention.versement_3_v2, 0::bigint)),
    subvention.montant_avoir_v2,
    subvention.versement_1_v2, subvention.versement_2_v2, subvention.versement_3_v2,
    subvention.date_versement_1_v2, subvention.date_versement_2_v2, subvention.date_versement_3_v2,
    personne.nom, personne.prenom,
    concat_ws(', ', (personne.contact -> 'coop') ->> 'email',
                   (personne.contact -> 'idposte') ->> 'mail_pro',
                   (personne.contact -> 'idposte') ->> 'mail_perso'),
    contrat.type, contrat.date_debut, contrat.date_fin, contrat.date_rupture,
    CASE WHEN contrat.date_rupture IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END,
    formation.lot, formation.marche_formation, formation.label,
    formation.date_debut, formation.date_fin, formation.lieu, formation.parcours,
    formation.observations, NULL::text,
    CASE WHEN poste.poste_renouvele IS TRUE THEN 'Oui'::text
         WHEN poste.poste_renouvele IS FALSE THEN 'Non'::text
         ELSE NULL::text END,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie),
    contact_ref.nom::text, contact_ref.prenom::text, contact_ref.telephone::text, contact_ref.email::text,
    NULL::text, NULL::text,
    CASE WHEN formation.pix IS TRUE THEN 'Oui'::text
         WHEN formation.pix IS FALSE THEN 'Non'::text
         ELSE NULL::text END,
    CASE WHEN formation.remn IS TRUE THEN 'Oui'::text
         WHEN formation.remn IS FALSE THEN 'Non'::text
         ELSE NULL::text END
  FROM main.structure_administrative sa
  LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
  LEFT JOIN admin.coll_terr ON coll_terr.code_insee::text = adresse.code_insee::text
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  JOIN main.poste ON sa.id = poste.structure_id
  LEFT JOIN main.personne ON poste.personne_id = personne.id
  LEFT JOIN main.formation ON personne.id = formation.personne_id
  LEFT JOIN main.contrat ON contrat.personne_id = personne.id
  LEFT JOIN main.subvention ON subvention.poste_id = poste.id
  LEFT JOIN LATERAL (
    SELECT c.nom, c.prenom, c.telephone, c.email
    FROM main.contact_structure_administrative cs
    JOIN main.contact c ON c.id = cs.contact_id
    WHERE cs.structure_administrative_id = sa.id
    ORDER BY c.id LIMIT 1
  ) contact_ref ON true
  WHERE subvention.date_debut_financement_ditp IS NOT NULL

  UNION ALL

  -- DGE
  SELECT
    poste.poste_conum_id, sa.structure_tp_id, personne.cn_pg_id,
    poste.etat, poste.date_attribution, poste.date_rendu_poste,
    poste.typologie, poste.action_coselec, poste.origine_transfert,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene),
    sa.siret,
    CASE WHEN sa.publique IS TRUE THEN 'Publique'::text ELSE 'Privée'::text END,
    cj.nom,
    poste.etat_instruction_v1, poste.etat_instruction_v2,
    coll_terr.region_nom, coll_terr.departement_nom, coll_terr.departement_code,
    adresse.code_postal, coll_terr.commune_nom, coll_terr.code_insee,
    'DGE'::text,
    subvention.date_debut_convention_dge, subvention.date_fin_convention_dge,
    subvention.date_debut_financement_dge, subvention.date_fin_financement_dge,
    subvention.mois_utilises_periode_financement_dge,
    NULL::smallint,
    subvention.montant_subvention_v2 - COALESCE(subvention.montant_bonification_v2, 0::bigint),
    CASE WHEN subvention.montant_bonification_v2 > 0 THEN 'Oui'::text ELSE 'Non'::text END,
    subvention.montant_bonification_v2,
    subvention.montant_subvention_v2,
    NULL::bigint,
    CASE WHEN subvention.montant_subvention_v2 > 0
         THEN (COALESCE(subvention.versement_1_v2, 0::bigint) + COALESCE(subvention.versement_2_v2, 0::bigint) + COALESCE(subvention.versement_3_v2, 0::bigint))::numeric / subvention.montant_subvention_v2::numeric
         ELSE NULL::numeric END,
    subvention.montant_subvention_v2 - (COALESCE(subvention.versement_1_v2, 0::bigint) + COALESCE(subvention.versement_2_v2, 0::bigint) + COALESCE(subvention.versement_3_v2, 0::bigint)),
    subvention.montant_avoir_v2,
    subvention.versement_1_v2, subvention.versement_2_v2, subvention.versement_3_v2,
    subvention.date_versement_1_v2, subvention.date_versement_2_v2, subvention.date_versement_3_v2,
    personne.nom, personne.prenom,
    concat_ws(', ', (personne.contact -> 'coop') ->> 'email',
                   (personne.contact -> 'idposte') ->> 'mail_pro',
                   (personne.contact -> 'idposte') ->> 'mail_perso'),
    contrat.type, contrat.date_debut, contrat.date_fin, contrat.date_rupture,
    CASE WHEN contrat.date_rupture IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END,
    formation.lot, formation.marche_formation, formation.label,
    formation.date_debut, formation.date_fin, formation.lieu, formation.parcours,
    formation.observations, NULL::text,
    CASE WHEN poste.poste_renouvele IS TRUE THEN 'Oui'::text
         WHEN poste.poste_renouvele IS FALSE THEN 'Non'::text
         ELSE NULL::text END,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie),
    contact_ref.nom::text, contact_ref.prenom::text, contact_ref.telephone::text, contact_ref.email::text,
    NULL::text, NULL::text,
    CASE WHEN formation.pix IS TRUE THEN 'Oui'::text
         WHEN formation.pix IS FALSE THEN 'Non'::text
         ELSE NULL::text END,
    CASE WHEN formation.remn IS TRUE THEN 'Oui'::text
         WHEN formation.remn IS FALSE THEN 'Non'::text
         ELSE NULL::text END
  FROM main.structure_administrative sa
  LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
  LEFT JOIN admin.coll_terr ON coll_terr.code_insee::text = adresse.code_insee::text
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  JOIN main.poste ON sa.id = poste.structure_id
  LEFT JOIN main.personne ON poste.personne_id = personne.id
  LEFT JOIN main.formation ON personne.id = formation.personne_id
  LEFT JOIN main.contrat ON contrat.personne_id = personne.id
  LEFT JOIN main.subvention ON subvention.poste_id = poste.id
  LEFT JOIN LATERAL (
    SELECT c.nom, c.prenom, c.telephone, c.email
    FROM main.contact_structure_administrative cs
    JOIN main.contact c ON c.id = cs.contact_id
    WHERE cs.structure_administrative_id = sa.id
    ORDER BY c.id LIMIT 1
  ) contact_ref ON true
  WHERE subvention.date_debut_financement_dge IS NOT NULL
);

COMMENT ON VIEW dataviz.poste IS
  'Vue dataviz refondue phase 5.5 (V094). Pointe sur structure_administrative '
  '(FK poste.structure_id migree V078). nom_structure = COALESCE(denomination_antenne, denomination_sirene).';

-- ============================================================
-- 3) dataviz.poste_pseudonymisee — projection sans PII
-- ============================================================
CREATE VIEW dataviz.poste_pseudonymisee AS (
  SELECT
    id_poste, id_structure, id_cn, etat, date_attribution, date_rendu_de_poste,
    typologie, action_coselec, origine_transfert, nom_structure, siret,
    "publique/privée", typologie_juridique,
    "etat_de_l'instruction v1", "etat_de_l'instruction v2",
    "région", "nom_du_département", "code_département",
    code_postal, commune, code_insee,
    source_de_financement,
    "date_début/signature_convention", date_fin_convention,
    "date_début_financement", date_de_fin_financement,
    "mois_consommés_sur_la_période_de_financement", "mois_consommés_sur_le_poste",
    montant_subventions_hors_bonification, territoire_prioritaire,
    "bonification découlant du lieu de permanence", montant_subventions_total,
    "cp_à_date", "cp_consommé", "reste_à_payer_convention", avoir,
    montant_versement_1e_tranche, montant_versement_2e_tranche, montant_versement_3e_tranche,
    date_versement_1e_tranche, date_versement_2e_tranche, date_versement_3e_tranche,
    type_ct, date_debut_contrat, date_fin_contrat, date_rupture, "rupture_anticipée",
    lot, "marché_de_formation", formation, "date_de_départ", date_de_fin,
    lieu, parcours, statut_formation_conum, cra, "poste_renouvelé",
    adresse_structure, pix, remn
  FROM dataviz.poste
);

-- ============================================================
-- 4) dataviz.lieux_inclusion_numerique
-- ============================================================
-- Cote LI uniquement (visible_pour_cartographie_nationale = TRUE filtre legacy
-- via structure_cartographie_nationale_id IS NOT NULL : memes lieux puisque
-- ces 2 colonnes ont migre ensemble en V074).
CREATE VIEW dataviz.lieux_inclusion_numerique AS (
  WITH conseillers AS (
    SELECT pal.lieu_id,
           COUNT(*) AS nbr
    FROM main.personne p
    JOIN main.personne_affectations_lieu pal ON pal.personne_id = p.id
    WHERE (p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL)
      AND pal.est_active = TRUE
    GROUP BY pal.lieu_id
  ), coop_lieu AS (
    SELECT lieu_id, COUNT(*) AS nbr
    FROM main.activites_coop
    GROUP BY lieu_id
  )
  SELECT
    li.id AS structure_id,
    li.nom,
    sa.siret,
    sa.rna,
    cj.nom AS "catégorie_juridique_de_la_structure",
    sa.etat_administratif AS "état_administratif_de_la_structure",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse,
    li.presentation_resume AS "présentation_résumée",
    li.presentation_detail AS "présentation_détaillée",
    li.horaires AS horaires_accueil,
    array_to_string(li.services, ', ') AS "services_proposés",
    array_to_string(li.dispositif_programmes_nationaux, ', ') AS dispositifs_nationaux,
    array_to_string(
      li.formations_labels ||
      NULLIF(NULLIF(NULLIF(li.autres_formations_labels, '{ZRR}'::text[]), '{QPV}'::text[]), '{QPV,ZRR}'::text[]),
      ', '
    ) AS formations,
    array_to_string(li.itinerance, ', ') AS "itinérance",
    array_to_string(li.modalites_acces, ', ') AS "modalités_accès",
    array_to_string(li.modalites_accompagnement, ', ') AS "modalités_accompagnement",
    li.mediateurs_en_activite AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    coop_lieu.nbr AS nombre_accompagnements,
    array_to_string(li.typologies, ', ') AS typologies,
    CASE WHEN zonage.type::text = 'QPV' THEN zonage.libelle ELSE 'Non'::varchar END AS qpv,
    CASE WHEN zonage.type::text = 'FRR' THEN 'Oui'::text ELSE 'Non'::text END AS frr,
    CASE WHEN 'France Services' = ANY (li.dispositif_programmes_nationaux) THEN 'Oui'::text ELSE 'Non'::text END AS est_france_services,
    CASE WHEN sa.structure_coop_id IS NOT NULL OR li.structure_coop_id IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "employeur_conseiller_numérique",
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
  FROM main.lieu_inclusion li
  LEFT JOIN main.adresse ON li.adresse_id = adresse.id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN main.lieu_inclusion_structure_administrative asso ON asso.lieu_id = li.id
  LEFT JOIN main.structure_administrative sa ON sa.id = asso.structure_administrative_id
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))
  LEFT JOIN conseillers ON li.id = conseillers.lieu_id
  LEFT JOIN coop_lieu ON li.id = coop_lieu.lieu_id
  WHERE li.structure_cartographie_nationale_id IS NOT NULL
);

COMMENT ON VIEW dataviz.lieux_inclusion_numerique IS
  'Vue dataviz refondue phase 5.5 (V094). Cote LI avec asso optionnelle vers SA pour SIRENE.';

-- ============================================================
-- 5) dataviz.personne
-- ============================================================
CREATE VIEW dataviz.personne AS (
  WITH lieux AS (
    SELECT pal.personne_id,
           MIN(qpv.id) AS qpv,
           MIN(frr.id) AS frr,
           COUNT(*) AS nbr,
           CASE WHEN bool_or('France Services' = ANY (li.dispositif_programmes_nationaux)) THEN 'Oui'::text ELSE 'Non'::text END AS est_france_services
    FROM main.personne_affectations_lieu pal
    JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
    JOIN main.adresse adresse ON adresse.id = li.adresse_id
    LEFT JOIN admin.zonage qpv ON qpv.type::text = 'QPV' AND st_contains(qpv.geom, adresse.geom)
    LEFT JOIN admin.zonage frr ON frr.type::text = 'FRR' AND adresse.code_insee::text = frr.code_insee::text
    WHERE pal.est_active = TRUE
    GROUP BY pal.personne_id
  ), coop AS (
    SELECT personne_id, COUNT(*) AS nbr
    FROM main.activites_coop
    GROUP BY personne_id
  )
  SELECT
    personne.id AS "Personne ID",
    sa.id AS "Structure employeuse ID",
    personne.nom AS "Nom",
    personne.prenom AS "Prénom",
    (personne.contact -> 'coop') ->> 'telephone' AS "Téléphone",
    concat_ws(', ', (personne.contact -> 'coop') ->> 'email',
                    (personne.contact -> 'idposte') ->> 'mail_pro',
                    (personne.contact -> 'idposte') ->> 'mail_perso') AS emails,
    CASE WHEN personne.conseiller_numerique_id IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "Conseiller Numérique",
    CASE WHEN personne.is_coordinateur IS TRUE THEN 'Oui'::text
         WHEN personne.is_coordinateur IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Coordinateur",
    CASE WHEN EXISTS (
           SELECT 1 FROM main.personne_affectations_emploi pae
           WHERE pae.personne_id = personne.id
             AND pae.source = 'aidants-connect' AND pae.est_active = TRUE
         ) THEN 'Oui'::text
         WHEN personne.aidant_connect_id IS NOT NULL THEN 'Non'::text
         ELSE NULL::text END AS "Aidants Connect",
    CASE WHEN personne.is_mediateur = TRUE THEN 'Médiateur'::text
         WHEN personne.is_mediateur = FALSE OR personne.is_mediateur IS NULL THEN 'Aidant numérique'::text
         ELSE NULL::text END AS "Type accompagnateur",
    CASE WHEN EXISTS (
           SELECT 1 FROM main.personne_affectations_emploi pae
           WHERE pae.personne_id = personne.id AND pae.est_active = TRUE
         ) THEN 'Oui'::text ELSE 'Non'::text END AS "En poste",
    CASE WHEN lieux.qpv IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "QPV",
    CASE WHEN lieux.frr IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "FRR",
    lieux.nbr AS "Lieux activités",
    lieux.est_france_services AS lieux_france_services,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS "Structure employeuse",
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure_employeuse,
    adresse.code_postal AS code_postal_structure_employeuse,
    commune.nom AS commune_structure_employeuse,
    personne.nb_accompagnements_ac AS nombre_accompagnements_aidants_connect,
    coop.nbr AS nombre_accompagnements_coop,
    NULLIF(COALESCE(personne.nb_accompagnements_ac, 0) + COALESCE(coop.nbr, 0::bigint), 0) AS nombre_accompagnements_totaux,
    CASE WHEN personne.formation_fne_ac IS TRUE THEN 'Oui'::text ELSE 'Non'::text END AS "Formation FNE",
    formation.label AS "Formation",
    formation.date_debut AS "date de début formation",
    formation.date_fin AS "date de fin formation",
    CASE WHEN formation.pix IS TRUE THEN 'Oui'::text
         WHEN formation.pix IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Certification PIX",
    CASE WHEN formation.remn IS TRUE THEN 'Oui'::text
         WHEN formation.remn IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Certification REMN"
  FROM main.personne
  LEFT JOIN main.personne_affectations_emploi pae ON personne.id = pae.personne_id AND pae.est_active = TRUE
  LEFT JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
  LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
  LEFT JOIN admin.commune ON adresse.code_insee::text = commune.code_insee::text
  LEFT JOIN main.formation ON personne.id = formation.personne_id
  LEFT JOIN lieux ON personne.id = lieux.personne_id
  LEFT JOIN coop ON personne.id = coop.personne_id
);

COMMENT ON VIEW dataviz.personne IS
  'Vue dataviz refondue phase 5.5 (V094). paf_emploi pour structure employeuse (SA), paf_lieu pour lieux d''activite (LI).';

-- ============================================================
-- 6) dataviz.personne_pseudonymisee
-- ============================================================
CREATE VIEW dataviz.personne_pseudonymisee AS (
  WITH lieux AS (
    SELECT pal.personne_id,
           MIN(qpv.id) AS qpv,
           MIN(frr.id) AS frr,
           COUNT(*) AS nbr,
           CASE WHEN bool_or('France Services' = ANY (li.dispositif_programmes_nationaux)) THEN 'Oui'::text ELSE 'Non'::text END AS est_france_services
    FROM main.personne_affectations_lieu pal
    JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
    JOIN main.adresse adresse ON adresse.id = li.adresse_id
    LEFT JOIN admin.zonage qpv ON qpv.type::text = 'QPV' AND st_contains(qpv.geom, adresse.geom)
    LEFT JOIN admin.zonage frr ON frr.type::text = 'FRR' AND adresse.code_insee::text = frr.code_insee::text
    WHERE pal.est_active = TRUE
    GROUP BY pal.personne_id
  ), coop AS (
    SELECT personne_id, COUNT(*) AS nbr
    FROM main.activites_coop
    GROUP BY personne_id
  )
  SELECT
    CASE WHEN personne.conseiller_numerique_id IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "Conseiller Numérique",
    CASE WHEN personne.is_coordinateur IS TRUE THEN 'Oui'::text
         WHEN personne.is_coordinateur IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Coordinateur",
    CASE WHEN EXISTS (
           SELECT 1 FROM main.personne_affectations_emploi pae
           WHERE pae.personne_id = personne.id
             AND pae.source = 'aidants-connect' AND pae.est_active = TRUE
         ) THEN 'Oui'::text
         WHEN personne.aidant_connect_id IS NOT NULL THEN 'Non'::text
         ELSE NULL::text END AS "Aidants Connect",
    CASE WHEN personne.is_mediateur = TRUE THEN 'Médiateur'::text
         WHEN personne.is_mediateur = FALSE OR personne.is_mediateur IS NULL THEN 'Aidant numérique'::text
         ELSE NULL::text END AS "Type accompagnateur",
    CASE WHEN EXISTS (
           SELECT 1 FROM main.personne_affectations_emploi pae
           WHERE pae.personne_id = personne.id AND pae.est_active = TRUE
         ) THEN 'Oui'::text ELSE 'Non'::text END AS "En poste",
    CASE WHEN lieux.qpv IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "QPV",
    CASE WHEN lieux.frr IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "FRR",
    lieux.nbr AS "Lieux activités",
    lieux.est_france_services AS lieux_france_services,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS "Structure employeuse",
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure_employeuse,
    adresse.code_postal AS code_postal_structure_employeuse,
    commune.nom AS commune_structure_employeuse,
    personne.nb_accompagnements_ac AS nombre_accompagnements_aidants_connect,
    coop.nbr AS nombre_accompagnements_coop,
    NULLIF(COALESCE(personne.nb_accompagnements_ac, 0) + COALESCE(coop.nbr, 0::bigint), 0) AS nombre_accompagnements_totaux,
    CASE WHEN personne.formation_fne_ac IS TRUE THEN 'Oui'::text ELSE 'Non'::text END AS "Formation FNE",
    formation.label AS "Formation",
    formation.date_debut AS "date de début formation",
    formation.date_fin AS "date de fin formation",
    CASE WHEN formation.pix IS TRUE THEN 'Oui'::text
         WHEN formation.pix IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Certification PIX",
    CASE WHEN formation.remn IS TRUE THEN 'Oui'::text
         WHEN formation.remn IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Certification REMN"
  FROM main.personne
  LEFT JOIN main.personne_affectations_emploi pae ON personne.id = pae.personne_id AND pae.est_active = TRUE
  LEFT JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
  LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
  LEFT JOIN admin.commune ON adresse.code_insee::text = commune.code_insee::text
  LEFT JOIN main.formation ON personne.id = formation.personne_id
  LEFT JOIN lieux ON personne.id = lieux.personne_id
  LEFT JOIN coop ON personne.id = coop.personne_id
);

-- ============================================================
-- 7) dataviz.structures_employeuses
-- ============================================================
-- Cote SA + paf_emploi. activites_coop reste cote LI (lieu_id pointe sur LI)
-- mais on agrege par SA via l'asso.
CREATE VIEW dataviz.structures_employeuses AS (
  WITH coordinateurs AS (
    SELECT pae.structure_administrative_id,
           COUNT(*) AS nbr
    FROM main.personne p
    JOIN main.personne_affectations_emploi pae ON p.id = pae.personne_id
    WHERE p.is_coordinateur IS TRUE AND pae.est_active = TRUE
    GROUP BY pae.structure_administrative_id
  ), conseillers AS (
    SELECT pae.structure_administrative_id,
           COUNT(*) AS nbr
    FROM main.personne p
    JOIN main.personne_affectations_emploi pae ON p.id = pae.personne_id
    WHERE (p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL)
      AND pae.est_active = TRUE
    GROUP BY pae.structure_administrative_id
  ), aidants_connect AS (
    SELECT pae.structure_administrative_id,
           COUNT(*) AS nbr_rattach,
           SUM(COALESCE(
             CASE WHEN sa.structure_ac_id IS NOT NULL THEN p.nb_accompagnements_ac ELSE 0 END,
             0
           )) AS nbr_accompagnements
    FROM main.personne p
    JOIN main.personne_affectations_emploi pae ON p.id = pae.personne_id AND pae.est_active = TRUE
    LEFT JOIN main.structure_administrative sa ON pae.structure_administrative_id = sa.id
    WHERE EXISTS (
            SELECT 1 FROM main.personne_affectations_emploi pae2
            WHERE pae2.personne_id = p.id
              AND pae2.source = 'aidants-connect'
              AND pae2.est_active = TRUE
          )
       OR p.aidant_connect_id IS NOT NULL
    GROUP BY pae.structure_administrative_id
  ), coop AS (
    -- activites_coop cote LI, ramene a la SA via asso.
    SELECT asso.structure_administrative_id,
           COUNT(*) AS nbr
    FROM main.activites_coop ac
    JOIN main.lieu_inclusion_structure_administrative asso ON asso.lieu_id = ac.lieu_id
    JOIN main.structure_administrative sa ON sa.id = asso.structure_administrative_id
    WHERE sa.structure_coop_id IS NOT NULL
    GROUP BY asso.structure_administrative_id
  ), aggregats_li AS (
    -- mediateurs_en_activite / dispositif_programmes_nationaux / France Services
    -- vivent sur LI. On agrege a la SA via asso (max sur mediateurs, bool_or
    -- sur France Services).
    SELECT asso.structure_administrative_id,
           MAX(li.mediateurs_en_activite) AS mediateurs_en_activite,
           bool_or('France Services' = ANY (li.dispositif_programmes_nationaux)) AS est_france_services
    FROM main.lieu_inclusion li
    JOIN main.lieu_inclusion_structure_administrative asso ON asso.lieu_id = li.id
    GROUP BY asso.structure_administrative_id
  )
  SELECT
    sa.id AS structure_id,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom,
    sa.siret,
    sa.rna,
    sa.code_activite_principale AS code_naf,
    cj.nom AS "catégorie_juridique_de_la_structure",
    sa.etat_administratif AS "état_administratif_de_la_structure",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse,
    CASE WHEN zonage.type::text = 'QPV' THEN zonage.libelle ELSE 'Non'::varchar END AS qpv,
    CASE WHEN zonage.type::text = 'FRR' THEN 'Oui'::text ELSE 'Non'::text END AS frr,
    CASE WHEN COALESCE(conseillers.nbr, 0::bigint) > 0 THEN 'Oui'::text ELSE 'Non'::text END AS est_conum,
    CASE WHEN COALESCE(aidants_connect.nbr_rattach, 0::bigint) > 0 THEN 'Oui'::text ELSE 'Non'::text END AS est_aidant_connect,
    CASE WHEN aggregats_li.est_france_services IS TRUE THEN 'Oui'::text ELSE 'Non'::text END AS est_france_services,
    aggregats_li.mediateurs_en_activite AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    aidants_connect.nbr_rattach AS nombre_aidants_connect,
    coordinateurs.nbr AS nombre_de_coordinateurs,
    sa.nb_mandats_ac AS mandats_aidants_connect,
    aidants_connect.nbr_accompagnements AS accompagnements_aidants_connect,
    coop.nbr AS "nombre_accompagnements_médiateurs_numériques",
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
  FROM main.structure_administrative sa
  LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  LEFT JOIN coordinateurs ON sa.id = coordinateurs.structure_administrative_id
  LEFT JOIN conseillers ON sa.id = conseillers.structure_administrative_id
  LEFT JOIN aidants_connect ON sa.id = aidants_connect.structure_administrative_id
  LEFT JOIN coop ON sa.id = coop.structure_administrative_id
  LEFT JOIN aggregats_li ON sa.id = aggregats_li.structure_administrative_id
);

COMMENT ON VIEW dataviz.structures_employeuses IS
  'Vue dataviz refondue phase 5.5 (V094). SA + paf_emploi + asso vers LI pour agregats metier.';

-- ============================================================
-- 8) dataviz.zonages
-- ============================================================
CREATE VIEW dataviz.zonages AS (
  WITH adresses AS (
    SELECT adresse.id AS adresse_id,
           adresse.code_insee,
           CASE WHEN MAX(zone_qpv.id) > 0 THEN TRUE ELSE FALSE END AS qpv,
           CASE WHEN MAX(zone_frr.id) > 0 THEN TRUE ELSE FALSE END AS frr
    FROM main.adresse
    LEFT JOIN admin.zonage zone_qpv ON st_contains(zone_qpv.geom, adresse.geom) AND zone_qpv.type::text = 'QPV'
    LEFT JOIN admin.zonage zone_frr ON zone_frr.code_insee::text = adresse.code_insee::text AND zone_frr.type::text = 'FRR'
    GROUP BY adresse.id
    HAVING MAX(zone_qpv.id) > 0 OR MAX(zone_frr.id) > 0
  ), structures AS (
    -- Comptage par SA (entites legales)
    SELECT adresse.code_insee,
           CASE WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) = 0 THEN 'QPV'::text
                WHEN MAX(adresse.qpv::integer) = 0 AND MAX(adresse.frr::integer) > 0 THEN 'FRR'::text
                WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                ELSE NULL::text END AS zonage,
           COUNT(*) AS nbr
    FROM main.structure_administrative sa
    JOIN adresses adresse ON adresse.adresse_id = sa.adresse_id
    GROUP BY adresse.code_insee
  ), lieux AS (
    SELECT adresse.code_insee,
           CASE WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) = 0 THEN 'QPV'::text
                WHEN MAX(adresse.qpv::integer) = 0 AND MAX(adresse.frr::integer) > 0 THEN 'FRR'::text
                WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                ELSE NULL::text END AS zonage,
           COUNT(*) AS nbr
    FROM main.lieu_inclusion li
    JOIN adresses adresse ON adresse.adresse_id = li.adresse_id AND li.visible_pour_cartographie_nationale
    GROUP BY adresse.code_insee
  ), activites AS (
    SELECT adresse.code_insee,
           CASE WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) = 0 THEN 'QPV'::text
                WHEN MAX(adresse.qpv::integer) = 0 AND MAX(adresse.frr::integer) > 0 THEN 'FRR'::text
                WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                ELSE NULL::text END AS zonage,
           SUM(activites_coop.accompagnements) AS nbr
    FROM main.activites_coop
    JOIN main.lieu_inclusion li ON li.id = activites_coop.lieu_id
    JOIN adresses adresse ON adresse.adresse_id = li.adresse_id
    WHERE li.visible_pour_cartographie_nationale
    GROUP BY adresse.code_insee
  ), activites_conum AS (
    SELECT adresse.code_insee,
           CASE WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) = 0 THEN 'QPV'::text
                WHEN MAX(adresse.qpv::integer) = 0 AND MAX(adresse.frr::integer) > 0 THEN 'FRR'::text
                WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                ELSE NULL::text END AS zonage,
           SUM(activites_coop.accompagnements) AS nbr
    FROM main.activites_coop
    JOIN main.lieu_inclusion li ON li.id = activites_coop.lieu_id
    JOIN adresses adresse ON adresse.adresse_id = li.adresse_id
    JOIN main.personne ON personne.id = activites_coop.personne_id
    WHERE li.visible_pour_cartographie_nationale AND personne.conseiller_numerique_id IS NOT NULL
    GROUP BY adresse.code_insee
  ), personnes AS (
    SELECT adresse.code_insee,
           CASE WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) = 0 THEN 'QPV'::text
                WHEN MAX(adresse.qpv::integer) = 0 AND MAX(adresse.frr::integer) > 0 THEN 'FRR'::text
                WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                ELSE NULL::text END AS zonage,
           COUNT(DISTINCT pal.personne_id) AS nbr
    FROM main.personne_affectations_lieu pal
    JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
    JOIN adresses adresse ON adresse.adresse_id = li.adresse_id
    WHERE li.visible_pour_cartographie_nationale AND pal.est_active = TRUE
    GROUP BY adresse.code_insee
  ), personnes_conum AS (
    SELECT adresse.code_insee,
           CASE WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) = 0 THEN 'QPV'::text
                WHEN MAX(adresse.qpv::integer) = 0 AND MAX(adresse.frr::integer) > 0 THEN 'FRR'::text
                WHEN MAX(adresse.qpv::integer) > 0 AND MAX(adresse.frr::integer) > 0 THEN 'QPV & FRR'::text
                ELSE NULL::text END AS zonage,
           COUNT(DISTINCT pal.personne_id) AS nbr
    FROM main.personne_affectations_lieu pal
    JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
    JOIN adresses adresse ON adresse.adresse_id = li.adresse_id
    JOIN main.personne ON personne.id = pal.personne_id
    WHERE li.visible_pour_cartographie_nationale AND pal.est_active = TRUE
      AND personne.conseiller_numerique_id IS NOT NULL
    GROUP BY adresse.code_insee
  ), zonages AS (
    SELECT t.zonage
    FROM (VALUES ('QPV'::text), ('FRR'::text), ('QPV & FRR'::text)) t(zonage)
  )
  SELECT
    coll_terr.region_nom AS region,
    coll_terr.departement_code AS code_departement,
    coll_terr.departement_nom AS departement,
    coll_terr.code_insee,
    coll_terr.commune_nom AS commune,
    zonages.zonage,
    structures.nbr AS nbr_structures,
    lieux.nbr AS nbr_lieux,
    activites.nbr AS nbr_accompagnements,
    activites_conum.nbr AS nbr_accompagnements_conum,
    personnes.nbr AS nbr_personnes,
    personnes_conum.nbr AS nbr_conseillers_numerique
  FROM admin.coll_terr
  CROSS JOIN zonages
  LEFT JOIN structures ON structures.code_insee::text = coll_terr.code_insee::text AND structures.zonage = zonages.zonage
  LEFT JOIN lieux ON lieux.code_insee::text = coll_terr.code_insee::text AND lieux.zonage = zonages.zonage
  LEFT JOIN activites ON activites.code_insee::text = coll_terr.code_insee::text AND activites.zonage = zonages.zonage
  LEFT JOIN activites_conum ON activites_conum.code_insee::text = coll_terr.code_insee::text AND activites_conum.zonage = zonages.zonage
  LEFT JOIN personnes ON personnes.code_insee::text = coll_terr.code_insee::text AND personnes.zonage = zonages.zonage
  LEFT JOIN personnes_conum ON personnes_conum.code_insee::text = coll_terr.code_insee::text AND personnes_conum.zonage = zonages.zonage
  WHERE structures.nbr IS NOT NULL OR lieux.nbr IS NOT NULL
     OR activites.nbr IS NOT NULL OR activites_conum.nbr IS NOT NULL
     OR personnes.nbr IS NOT NULL OR personnes_conum.nbr IS NOT NULL
  GROUP BY coll_terr.region_nom, coll_terr.departement_code, coll_terr.departement_nom,
           coll_terr.code_insee, coll_terr.commune_nom, zonages.zonage,
           structures.nbr, lieux.nbr, activites.nbr, activites_conum.nbr,
           personnes.nbr, personnes_conum.nbr
  ORDER BY coll_terr.departement_code, coll_terr.code_insee, zonages.zonage
);

COMMENT ON VIEW dataviz.zonages IS
  'Vue dataviz refondue phase 5.5 (V094). nbr_structures via SA, nbr_lieux/accompagnements/personnes via LI + paf_lieu.';

-- ============================================================
-- 9) dataviz.personnes_accompagnements
-- ============================================================
-- Fix sementique : `activites_coop.lieu_id` pointe sur LI depuis V084.
-- Le legacy faisait `JOIN main.structure s ON s.id = a.lieu_id` (toujours
-- valide en transition) puis `JOIN main.adresse addr ON addr.id = s.id` (BUG :
-- compare adresse.id avec structure.id !). On corrige le bug en passant par
-- li.adresse_id.
CREATE VIEW dataviz.personnes_accompagnements AS (
  WITH src AS (
    SELECT p.id AS personne_id,
           p.nom, p.prenom,
           CASE WHEN p.cn_pg_id IS NOT NULL THEN 'CoNum'::text
                WHEN p.cn_pg_id IS NULL AND p.aidant_connect_id IS NULL THEN 'Médiateur'::text
                ELSE NULL::text END AS role,
           a.periode, a.type, a.autonomie, a.type_lieu,
           a.thematiques, a.materiels
    FROM main.activites_coop a
    JOIN main.personne p ON p.id = a.personne_id
  ), base AS (
    SELECT personne_id, nom, prenom, periode, role, COUNT(*) AS nb_accompagnements
    FROM src
    GROUP BY personne_id, nom, prenom, periode, role
  ), counts AS (
    SELECT personne_id, periode, 'type'::text AS dim, type AS key, COUNT(*) AS n
    FROM src WHERE type IS NOT NULL GROUP BY personne_id, periode, type
    UNION ALL
    SELECT personne_id, periode, 'autonomie'::text, autonomie, COUNT(*)
    FROM src WHERE autonomie IS NOT NULL GROUP BY personne_id, periode, autonomie
    UNION ALL
    SELECT personne_id, periode, 'type_lieu'::text, type_lieu, COUNT(*)
    FROM src WHERE type_lieu IS NOT NULL GROUP BY personne_id, periode, type_lieu
    UNION ALL
    SELECT s.personne_id, s.periode, 'thematique'::text, t.t, COUNT(*)
    FROM src s LEFT JOIN LATERAL unnest(COALESCE(s.thematiques, ARRAY[]::text[])) t(t) ON TRUE
    WHERE t.t IS NOT NULL GROUP BY s.personne_id, s.periode, t.t
    UNION ALL
    SELECT s.personne_id, s.periode, 'materiel'::text, m.m, COUNT(*)
    FROM src s LEFT JOIN LATERAL unnest(COALESCE(s.materiels, ARRAY[]::text[])) m(m) ON TRUE
    WHERE m.m IS NOT NULL GROUP BY s.personne_id, s.periode, m.m
  ), zonages AS (
    SELECT a.personne_id, a.periode,
           MAX(CASE WHEN z.type::text = 'QPV' THEN 1 ELSE 0 END)::boolean AS qpv,
           MAX(CASE WHEN z.type::text = 'FRR' THEN 1 ELSE 0 END)::boolean AS frr
    FROM main.activites_coop a
    JOIN main.lieu_inclusion li ON li.id = a.lieu_id
    JOIN main.adresse addr ON addr.id = li.adresse_id
    JOIN admin.zonage z ON (z.type::text = 'FRR' AND addr.code_insee::text = z.code_insee::text)
                        OR (z.type::text = 'QPV' AND st_contains(z.geom, addr.geom))
    GROUP BY a.personne_id, a.periode
  )
  SELECT
    b.periode, b.personne_id, b.nom, b.prenom, b.role,
    COALESCE(z.qpv, FALSE) AS qpv,
    COALESCE(z.frr, FALSE) AS frr,
    b.nb_accompagnements,
    COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'type'), '{}'::jsonb) AS type_accompagnement,
    COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'materiel'), '{}'::jsonb) AS materiel,
    COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'autonomie'), '{}'::jsonb) AS autonomie,
    COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'type_lieu'), '{}'::jsonb) AS type_lieu,
    COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'thematique'), '{}'::jsonb) AS thematique
  FROM base b
  LEFT JOIN counts c ON c.personne_id = b.personne_id AND c.periode = b.periode
  LEFT JOIN zonages z ON z.personne_id = b.personne_id AND z.periode = b.periode
  GROUP BY b.periode, b.personne_id, b.nom, b.prenom, b.role, b.nb_accompagnements, z.qpv, z.frr
  ORDER BY b.periode, b.role, b.personne_id
);

COMMENT ON VIEW dataviz.personnes_accompagnements IS
  'Vue dataviz refondue phase 5.5 (V094). Fix : activites_coop.lieu_id pointe sur LI (V084). '
  'Le legacy comparait adresse.id avec structure.id par bug — corrige via li.adresse_id.';
