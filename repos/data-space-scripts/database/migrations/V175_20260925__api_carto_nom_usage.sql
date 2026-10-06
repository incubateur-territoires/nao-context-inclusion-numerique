-- V175 — api.carto : publier le nom d'usage quand il est renseigné (SEPT #1996).
--
-- La coop va lancer en production le job unique `reprendre-les-donnees-des-lieux`,
-- qui aligne les lieux sur le standard national et écrit chaque correction dans
-- `coop.lieu_inclusion` ET dans le registre `main.lieu_inclusion` (via
-- structure_coop_id, même transaction). Parmi ces corrections : quand le SIRET
-- d'un lieu est légitime et que la dénomination SIRENE diffère du nom saisi, le
-- job écrit `nom` ← dénomination SIRENE et `nom_usage` ← l'ancien nom du lieu.
-- Ordre de grandeur annoncé sur une copie de prod : plusieurs centaines de lieux.
--
-- Or `api.carto` ne lit que `li.nom` depuis sa création (V162 → V167) : après le
-- job, la cartographie nationale publierait la raison sociale SIRENE à la place
-- du nom destiné au public, pour ces lieux. `nom_usage` existe pourtant depuis
-- V121 (2026-07-08) et est propagée par la vue union V153.
--
-- ⚠️ Cette migration doit être en production AVANT le lancement du job coop.
-- Elle est indépendante de V174 : aucune contrainte d'ordre entre les deux.
--
-- Le cast `::character varying(255)` n'est pas décoratif : `main.lieu_inclusion.nom`
-- et `nom_usage` sont tous deux `varchar(255)`, mais `COALESCE` en perd la longueur
-- et renvoie `character varying` — `CREATE OR REPLACE VIEW` refuserait alors de
-- changer le type de la colonne `nom`, déjà `varchar(255)`.
--
-- Seule l'expression de la colonne `nom` change : nom, type et ordre des colonnes
-- identiques à V167 → CREATE OR REPLACE conserve l'OID et les GRANT
-- (postgrest_anct_carto, postgrest_anct_data_incl). Bloc défensif identique à
-- V167 : sur une base sans schéma coop (CI test_migration), la vue n'existe pas
-- → no-op.
--
-- Mesure sur dev (réplique, 2026-09-25) : 18 772 lignes servies, dont 1 seule
-- porte un nom_usage — et il diffère du nom. La migration est donc sans effet
-- visible aujourd'hui ; elle prépare le job.

DO $mig$
BEGIN
    IF to_regclass('coop.users') IS NULL OR to_regclass('coop.mediateurs') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : V175 ignorée.';
        RETURN;
    END IF;

    EXECUTE $v1$
    CREATE OR REPLACE VIEW api.carto AS
 WITH courriels AS (
         SELECT li_1.id,
            string_agg(v.value, '|'::text) AS courriels_concat
           FROM main.lieu_inclusion li_1,
            LATERAL jsonb_each_text(jsonb_extract_path(li_1.contact, VARIADIC ARRAY['courriels'::text])) v(key, value)
          WHERE v.key = 'email'::text
          GROUP BY li_1.id
        ), personnes AS (
         SELECT pv.lieu_id,
            jsonb_strip_nulls(jsonb_agg(jsonb_build_object('prenom', pv.prenom, 'nom', pv.nom, 'label', pv.label, 'email', pv.email, 'telephone', pv.telephone))) AS mediateurs
           FROM main.personne_visibilite_carto pv
          WHERE pv.expose
          GROUP BY pv.lieu_id
        )
 SELECT li.structure_cartographie_nationale_id AS id,
    '00000000000000'::character varying(14) AS pivot,
    COALESCE(li.nom_usage, li.nom)::character varying(255) AS nom,
    jsonb_build_object('numero_voie', a.numero_voie, 'repetition', a.repetition, 'nom_voie', a.nom_voie, 'code_postal', a.code_postal, 'commune', a.nom_commune, 'code_insee', a.code_insee) AS adresse,
    st_y(a.geom) AS latitude,
    st_x(a.geom) AS longitude,
    li.typologies AS typologie,
    jsonb_extract_path_text(li.contact, VARIADIC ARRAY['telephone'::text]) AS telephone,
    courriels.courriels_concat AS courriels,
    jsonb_extract_path_text(li.contact, VARIADIC ARRAY['site_web'::text]) AS site_web,
    li.horaires,
    li.presentation_resume,
    li.presentation_detail,
    li.source,
    li.itinerance,
    COALESCE(li.updated_at, li.created_at) AS date_maj,
    li.services,
    li.publics_specifiquement_adresses,
    li.prise_en_charge_specifique,
    li.frais_a_charge,
    li.dispositif_programmes_nationaux,
    li.formations_labels,
    li.autres_formations_labels,
    li.modalites_acces,
    li.modalites_accompagnement,
    li.prise_rdv,
    personnes.mediateurs
   FROM main.lieu_inclusion li
     LEFT JOIN main.adresse a ON a.id = li.adresse_id
     LEFT JOIN courriels ON courriels.id = li.id
     LEFT JOIN personnes ON personnes.lieu_id = li.id
  WHERE li.structure_cartographie_nationale_id IS NOT NULL
    AND li.visible_pour_cartographie_nationale = true
    AND li.deleted_at IS NULL
    $v1$;

    EXECUTE $c8$ COMMENT ON VIEW api.carto IS $t8$ Vue cartographie publique — LA photo du dataspace (V162, SEPT #1724) : lecture pure du référentiel main.lieu_inclusion. `nom` = COALESCE(nom_usage, nom) depuis V175 (SEPT #1996) : le nom d'usage prime, sinon le nom — sans quoi la reprise des données coop publierait la raison sociale SIRENE à la place du nom destiné au public. `mediateurs` : agrégation de main.personne_visibilite_carto (V165, SEPT #1940 — règle de visibilité formalisée, iso V164 : coordonnées et visibilité lues en direct dans la coop, #1868). Un lieu s'affiche s'il est référencé (carto_id), visible et non supprimé — deleted_at filtré pour TOUTES les origines depuis V167 (SEPT #1950 : l'état d'un lieu appartient aux outils de gestion). `pivot` non renseigné depuis #1711. $t8$ $c8$;
END
$mig$;

NOTIFY pgrst, 'reload schema';
