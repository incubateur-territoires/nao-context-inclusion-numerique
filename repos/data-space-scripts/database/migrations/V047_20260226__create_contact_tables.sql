-- Table 1 : les contacts (données d'identité d'un contact)
CREATE TABLE "main"."contact" (
  "id" SERIAL PRIMARY KEY,
  "nom" VARCHAR(255) NOT NULL,
  "prenom" VARCHAR(255) NOT NULL,
  "email" VARCHAR(255) NOT NULL,
  "telephone" VARCHAR(20) NOT NULL DEFAULT '',
  "fonction" VARCHAR(255) NOT NULL DEFAULT '',
  "est_referent_fne" BOOLEAN NOT NULL DEFAULT FALSE,
  "created_at" TIMESTAMP(6) DEFAULT NOW(),
  "updated_at" TIMESTAMP(6) DEFAULT NOW()
);

-- Table 2 : table de jointure structure <-> contact
CREATE TABLE "main"."contact_structure" (
  "id" SERIAL PRIMARY KEY,
  "structure_id" INTEGER NOT NULL,
  "contact_id" INTEGER NOT NULL,
  "created_at" TIMESTAMP(6) DEFAULT NOW(),

  CONSTRAINT "contact_structure_structure_id_fkey"
    FOREIGN KEY ("structure_id") REFERENCES "main"."structure"("id")
    ON DELETE CASCADE ON UPDATE CASCADE,

  CONSTRAINT "contact_structure_contact_id_fkey"
    FOREIGN KEY ("contact_id") REFERENCES "main"."contact"("id")
    ON DELETE CASCADE ON UPDATE CASCADE,

  CONSTRAINT "contact_structure_unique" UNIQUE ("structure_id", "contact_id")
);

CREATE INDEX "contact_structure_structure_id_idx" ON "main"."contact_structure"("structure_id");
CREATE INDEX "contact_structure_contact_id_idx" ON "main"."contact_structure"("contact_id");

-- ============================================================
-- Migration de la table min.membre
-- ============================================================
-- CONTEXTE:
-- Le schéma "min" est normalement géré par Prisma, mais pour rendre cette migration
-- Flyway complètement autonome, on intègre ici les modifications de min.membre
-- qui étaient dispersées dans plusieurs migrations Prisma:
--   - 20250710130159_ajout_siret_ridet_membre
--   - 20250711142414_suppression_date_membres
--   - 20250929085813_lien_membre_structure
--   - 20251016110250_renommer_structure_id_en_old_structure_id
--
-- OBJECTIF:
-- Ajouter les colonnes nécessaires pour lier min.membre à main.structure
-- ============================================================

-- Supprimer les anciennes FK contact/contact_technique (seront recréées sans NOT NULL plus bas)
ALTER TABLE "min"."membre" DROP CONSTRAINT IF EXISTS "membre_contact_fkey";
ALTER TABLE "min"."membre" DROP CONSTRAINT IF EXISTS "membre_contact_technique_fkey";

-- Rendre contact et contact_technique nullable
ALTER TABLE "min"."membre" ALTER COLUMN "contact" DROP NOT NULL;
ALTER TABLE "min"."membre" ALTER COLUMN "contact_technique" DROP NOT NULL;

-- Ajouter les colonnes manquantes
ALTER TABLE "min"."membre" ADD COLUMN IF NOT EXISTS "siret_ridet" TEXT;
ALTER TABLE "min"."membre" ADD COLUMN IF NOT EXISTS "date_suppression" TIMESTAMP(3) WITHOUT TIME ZONE;
ALTER TABLE "min"."membre" ADD COLUMN IF NOT EXISTS "old_structure_id" INTEGER;
ALTER TABLE "min"."membre" ADD COLUMN IF NOT EXISTS "structure_id" INTEGER;

-- Créer la FK vers main.structure
ALTER TABLE "min"."membre"
  DROP CONSTRAINT IF EXISTS "membre_structure_id_fkey";

ALTER TABLE "min"."membre"
  ADD CONSTRAINT "membre_structure_id_fkey"
  FOREIGN KEY (structure_id)
  REFERENCES "main"."structure"(id)
  ON DELETE SET NULL
  ON UPDATE CASCADE;

-- Créer l'index sur structure_id
CREATE INDEX IF NOT EXISTS "idx_membre_structure_id" ON "min"."membre"(structure_id);

-- Peupler structure_id en utilisant siret_ridet (si disponible)
-- Note: siret_ridet peut être NULL si les données n'ont pas encore été importées
UPDATE "min"."membre" m
SET structure_id = ms.id
FROM "main"."structure" ms
WHERE m.siret_ridet IS NOT NULL
  AND ms.siret = m.siret_ridet
  AND m.structure_id IS NULL;

-- Migration des données depuis min.contact_membre_gouvernance + min.membre (contact + contact_technique)
INSERT INTO "main"."contact" ("nom", "prenom", "email", "fonction", "est_referent_fne")
SELECT DISTINCT
  cmg.nom,
  cmg.prenom,
  cmg.email,
  cmg.fonction,
  TRUE
FROM "min"."contact_membre_gouvernance" cmg
INNER JOIN "min"."membre" m ON m.contact = cmg.email OR m.contact_technique = cmg.email;

-- ============================================================
-- Création des liens contact_structure pour les contacts de gouvernance
-- ============================================================
-- Maintenant que min.membre.structure_id a été créé et peuplé ci-dessus,
-- on peut créer les liens entre contacts et structures de manière exhaustive.
-- ============================================================
WITH all_emails AS (
  -- Emails depuis min.membre.contact
  SELECT DISTINCT m.structure_id, m.contact AS email
  FROM "min"."membre" m
  WHERE m.structure_id IS NOT NULL AND m.contact IS NOT NULL

  UNION

  -- Emails depuis min.membre.contact_technique
  SELECT DISTINCT m.structure_id, m.contact_technique AS email
  FROM "min"."membre" m
  WHERE m.structure_id IS NOT NULL AND m.contact_technique IS NOT NULL
)
INSERT INTO "main"."contact_structure" ("structure_id", "contact_id")
SELECT DISTINCT
  ae.structure_id,
  c.id
FROM all_emails ae
INNER JOIN "main"."contact" c ON c.email = ae.email
WHERE NOT EXISTS (
  SELECT 1
  FROM "main"."contact_structure" cs
  WHERE cs.structure_id = ae.structure_id
    AND cs.contact_id = c.id
);

-- Migration des données depuis main.structure.contact (JSON)
INSERT INTO "main"."contact" ("nom", "prenom", "email", "telephone", "fonction")
SELECT
  (contact->>'nom')::text,
  (contact->>'prenom')::text,
  (contact->'courriels'->>'mail_gestionnaire')::text,
  COALESCE((contact->>'telephone')::text, ''),
  'contact structure'
FROM "main"."structure"
WHERE contact ? 'nom'
  AND contact ? 'prenom'
  AND contact->>'nom' IS NOT NULL
  AND contact->>'prenom' IS NOT NULL
  AND contact ? 'courriels'
  AND contact->'courriels' ? 'mail_gestionnaire'
  AND contact->'courriels'->'mail_gestionnaire' <> 'null'::jsonb;

INSERT INTO "main"."contact_structure" ("structure_id", "contact_id")
SELECT
  s.id,
  c.id
FROM "main"."structure" s
INNER JOIN "main"."contact" c
  ON c.email = (s.contact->'courriels'->>'mail_gestionnaire')::text
  AND c.nom = (s.contact->>'nom')::text
  AND c.prenom = (s.contact->>'prenom')::text
  AND c.fonction = 'contact structure'
WHERE s.contact ? 'nom'
  AND s.contact ? 'prenom'
  AND s.contact->>'nom' IS NOT NULL
  AND s.contact->>'prenom' IS NOT NULL
  AND s.contact ? 'courriels'
  AND s.contact->'courriels' ? 'mail_gestionnaire'
  AND s.contact->'courriels'->'mail_gestionnaire' <> 'null'::jsonb;

-- ============================================================
-- Mise à jour des vues et fonctions pour utiliser main.contact
-- + main.contact_structure au lieu de main.structure.contact
-- ============================================================

-- ============================================================
-- 1. Vue dataviz.poste : remplacer structure.contact par les
--    nouvelles tables main.contact / main.contact_structure
-- ============================================================
CREATE OR REPLACE VIEW dataviz.poste AS
SELECT poste.poste_conum_id AS id_poste,
    structure.structure_tp_id AS id_structure,
    personne.cn_pg_id AS id_cn,
    poste.etat,
    poste.date_attribution,
    poste.date_rendu_poste AS date_rendu_de_poste,
    poste.typologie,
    poste.action_coselec,
    poste.origine_transfert,
    structure.nom AS nom_structure,
    structure.siret,
    CASE
        WHEN structure.publique IS TRUE THEN 'Publique'
        ELSE 'Privée'
    END AS "publique/privée",
    categories_juridiques.nom AS typologie_juridique,
    poste.etat_instruction_v1 AS "etat_de_l'instruction v1",
    poste.etat_instruction_v2 AS "etat_de_l'instruction v2",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "nom_du_département",
    coll_terr.departement_code AS "code_département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    coll_terr.code_insee,
    subvention.source_financement AS source_de_financement,
    subvention.date_debut_convention AS "date_début/signature_convention",
    subvention.date_fin_convention,
    subvention.date_debut_financement AS "date_début_financement",
    subvention.date_fin_financement AS date_de_fin_financement,
    subvention.mois_utilises_periode_financement AS "mois_consommés_sur_la_période_de_financement",
    subvention.mois_utilises_poste AS "mois_consommés_sur_le_poste",
    subvention.montant_subvention AS montant_subventions_hors_bonification,
    CASE
        WHEN subvention.is_territoire_prioritaire IS NOT NULL THEN 'Oui'
        ELSE 'Non'
    END AS territoire_prioritaire,
    subvention.montant_bonification AS "bonification découlant du lieu de permanence",
    subvention.montant_subvention + subvention.montant_bonification AS montant_subventions_total,
    subvention.cp_a_date AS "cp_à_date",
    (subvention.versement_1 + subvention.versement_2 + subvention.versement_3) / (subvention.montant_subvention + subvention.montant_bonification) AS "cp_consommé",
    subvention.montant_subvention + subvention.montant_bonification - (subvention.versement_1 + subvention.versement_2 + subvention.versement_3) AS "reste_à_payer_convention",
    subvention.avoir,
    subvention.versement_1 AS montant_versement_1e_tranche,
    subvention.versement_2 AS montant_versement_2e_tranche,
    subvention.versement_3 AS montant_versement_3e_tranche,
    subvention.date_versement_1 AS date_versement_1e_tranche,
    subvention.date_versement_2 AS date_versement_2e_tranche,
    subvention.date_versement_3 AS date_versement_3e_tranche,
    personne.nom,
    personne.prenom AS "prénom",
    concat_ws(', ',
        personne.contact -> 'coop' ->> 'email',
        personne.contact -> 'idposte' ->> 'mail_pro',
        personne.contact -> 'idposte' ->> 'mail_perso'
    ) AS emails,
    contrat.type AS type_ct,
    contrat.date_debut AS date_debut_contrat,
    contrat.date_fin AS date_fin_contrat,
    contrat.date_rupture,
    CASE
        WHEN contrat.date_rupture IS NOT NULL THEN 'Oui'
        ELSE 'Non'
    END AS "rupture_anticipée",
    formation.lot,
    formation.marche_formation AS "marché_de_formation",
    formation.label AS formation,
    formation.date_debut AS "date_de_départ",
    formation.date_fin AS date_de_fin,
    formation.lieu,
    formation.parcours,
    formation.observations AS statut_formation_conum,
    NULL::text AS cra,
    CASE
        WHEN poste.poste_renouvele IS TRUE THEN 'Oui'
        WHEN poste.poste_renouvele IS FALSE THEN 'Non'
        ELSE NULL
    END AS "poste_renouvelé",
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure,
    contact_ref.nom::text AS "nom_référent_tp",
    contact_ref.prenom::text AS "prénom_référent_tp",
    contact_ref.telephone::text AS telephone,
    contact_ref.email::text AS mail_gestionnaire,
    NULL::text AS mail_2,
    NULL::text AS "référent_hiérarchique",
    CASE
        WHEN formation.pix IS TRUE THEN 'Oui'
        WHEN formation.pix IS FALSE THEN 'Non'
        ELSE NULL
    END AS pix,
    CASE
        WHEN formation.remn IS TRUE THEN 'Oui'
        WHEN formation.remn IS FALSE THEN 'Non'
        ELSE NULL
    END AS remn
FROM main.structure
    LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
    LEFT JOIN admin.coll_terr ON coll_terr.code_insee = adresse.code_insee
    LEFT JOIN reference.categories_juridiques ON structure.categorie_juridique = categories_juridiques.code
    JOIN main.poste ON structure.id = poste.structure_id
    LEFT JOIN main.personne ON poste.personne_id = personne.id
    LEFT JOIN main.formation ON personne.id = formation.personne_id
    LEFT JOIN main.contrat ON contrat.personne_id = personne.id
    LEFT JOIN main.subvention ON subvention.poste_id = poste.id
    LEFT JOIN LATERAL (
        SELECT c.nom, c.prenom, c.telephone, c.email
        FROM main.contact_structure cs
        JOIN main.contact c ON c.id = cs.contact_id
        WHERE cs.structure_id = structure.id
        ORDER BY c.id
        LIMIT 1
    ) contact_ref ON true;

-- ============================================================
-- 2. Fonction api.get_mediateur : remplacer structure.contact
--    par les nouvelles tables main.contact / main.contact_structure
-- ============================================================
CREATE OR REPLACE FUNCTION api.get_mediateur(email text)
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    var_personne_id integer;
BEGIN
    -- Rechercher la personne par email (toutes sources)
    SELECT p.id
    INTO var_personne_id
    FROM main.personne p
    WHERE p.contact -> 'coop' ->> 'email' = email
       OR p.contact -> 'idposte' ->> 'mail_pro' = email
       OR p.contact -> 'idposte' ->> 'mail_perso' = email
    LIMIT 1;

    RETURN QUERY
    WITH cn_coordonnes AS (
        SELECT coordinateur_id,
        jsonb_agg(
            jsonb_build_object(
                'ids', jsonb_build_object(
                    'dataspace', personne.id,
                    'aidant_connect', personne.aidant_connect_id,
                    'conseiller_numerique', personne.conseiller_numerique_id,
                    'pg_id', personne.cn_pg_id,
                    'coop', personne.coop_id),
                'nom', personne.nom,
                'prenom', personne.prenom,
                'contact', personne.contact
            )
        ) AS conseillers_numerique_coordonnes
        FROM main.coordination_mediation
        INNER JOIN main.personne ON personne.id = mediateur_id
        WHERE coordination_mediation.suppression IS NULL
        AND coordinateur_id = var_personne_id
        GROUP BY coordinateur_id
    ),
    structures_employeuses AS (
        SELECT personne_affectations.personne_id,
            jsonb_agg(
                jsonb_build_object(
                    'ids', jsonb_build_object(
                        'dataspace', structure.id,
                        'aidant_connect', structure.structure_ac_id,
                        'coop', structure.structure_coop_id,
                        'pg_id', structure.structure_tp_id),
                    'siret', structure.siret,
                    'nom', structure.nom,
                    'contacts', (
                        SELECT COALESCE(jsonb_agg(
                            jsonb_build_object(
                                'nom', c.nom,
                                'prenom', c.prenom,
                                'email', c.email,
                                'telephone', c.telephone,
                                'fonction', c.fonction,
                                'est_referent_fne', c.est_referent_fne
                            )
                        ), '[]'::jsonb)
                        FROM main.contact_structure cs
                        JOIN main.contact c ON c.id = cs.contact_id
                        WHERE cs.structure_id = structure.id
                    ),
                    'adresse', jsonb_build_object(
                        'code_postal', adresse.code_postal,
                        'code_insee', adresse.code_insee,
                        'nom_commune', adresse.nom_commune,
                        'nom_voie', adresse.nom_voie,
                        'repetition', adresse.repetition,
                        'numero_voie', adresse.numero_voie
                    ),
                    'contrats', (SELECT
                    jsonb_agg(
                        jsonb_build_object(
                            'date_debut', contrat.date_debut,
                            'date_fin', contrat.date_fin,
                            'date_rupture', contrat.date_rupture,
                            'type', contrat.type
                        )
                    )
                    FROM main.contrat
                    WHERE (contrat.structure_id = structure.id OR contrat.structure_id IS NULL) AND contrat.personne_id = personne_affectations.personne_id)
                )
            ) AS structures
        FROM main.personne_affectations
        INNER JOIN main.structure ON structure.id = personne_affectations.structure_id
        LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
        WHERE personne_affectations.personne_id = var_personne_id
        AND personne_affectations.type = 'structure_emploi'
        GROUP BY personne_affectations.personne_id
    ),
    lieux_activite AS (
        SELECT personne_id,
        jsonb_agg(
            jsonb_build_object(
                'siret', structure.siret,
                'nom', structure.nom,
                'contacts', (
                    SELECT COALESCE(jsonb_agg(
                        jsonb_build_object(
                            'nom', c.nom,
                            'prenom', c.prenom,
                            'email', c.email,
                            'telephone', c.telephone,
                            'fonction', c.fonction,
                            'est_referent_fne', c.est_referent_fne
                        )
                    ), '[]'::jsonb)
                    FROM main.contact_structure cs
                    JOIN main.contact c ON c.id = cs.contact_id
                    WHERE cs.structure_id = structure.id
                ),
                'adresse', jsonb_build_object(
                    'code_postal', adresse.code_postal,
                    'code_insee', adresse.code_insee,
                    'nom_commune', adresse.nom_commune,
                    'nom_voie', adresse.nom_voie,
                    'repetition', adresse.repetition,
                    'numero_voie', adresse.numero_voie
                ),
                'id_carto', structure_cartographie_nationale_id
            )
        ) AS lieux
        FROM main.personne_affectations AS lieux
        INNER JOIN main.structure ON structure.structure_coop_id = lieux.structure_coop_id
        LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
        LEFT JOIN admin.coll_terr ON coll_terr.code_insee = adresse.code_insee
        WHERE personne_id = var_personne_id AND type = 'lieu_activite'
        GROUP BY personne_id
    ),
    is_cn AS (
        SELECT pa.personne_id
        FROM main.personne_affectations pa
        WHERE pa.personne_id = var_personne_id
        AND pa.source = 'idposte'
        AND pa.est_active = TRUE
        AND pa.type = 'structure_emploi'
        LIMIT 1
    )
    SELECT jsonb_build_object(
        'id', personne.id,
        'is_conseiller_numerique', CASE WHEN is_cn.personne_id IS NOT NULL THEN True ELSE False END,
        'pg_id', personne.cn_pg_id,
        'is_coordinateur', CASE WHEN is_coordinateur IS True THEN True ELSE False END,
        'structures_employeuses', structures.structures,
        'conseillers_numeriques_coordonnes', cn_coordonnes.conseillers_numerique_coordonnes,
        'lieux_activite', lieux_activite.lieux
    )
    FROM main.personne
    LEFT JOIN cn_coordonnes ON cn_coordonnes.coordinateur_id = personne.id
    LEFT JOIN lieux_activite ON lieux_activite.personne_id = personne.id
    LEFT JOIN structures_employeuses AS structures ON structures.personne_id = personne.id
    LEFT JOIN is_cn ON is_cn.personne_id = personne.id
    WHERE personne.id = var_personne_id
    GROUP BY personne.id, conseiller_numerique_id, is_coordinateur, structures.structures, cn_coordonnes.conseillers_numerique_coordonnes, lieux_activite.lieux, is_cn.personne_id;
END;
$function$;

