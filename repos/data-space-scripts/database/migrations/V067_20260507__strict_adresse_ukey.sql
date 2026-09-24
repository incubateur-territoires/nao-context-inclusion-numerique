-- Renforce la contrainte d'unicité sur main.adresse pour fermer le trou des
-- adresses "pauvres" sans nom_voie : l'index précédent traitait NULL comme
-- distinct (sémantique par défaut), donc plusieurs lignes (CP, commune, NULL,
-- ...) identiques pouvaient coexister.
-- Conséquences observées : 530+ groupes de doublons, 17k+ adresses orphelines
-- créées par le géocodage IGN qui retombe sur le centroïde commune.
--
-- Solution : recréer l'index avec NULLS NOT DISTINCT (PG 15+). Aucun ON
-- CONFLICT existant à modifier — la sémantique de l'index s'applique
-- automatiquement aux UPSERT.
--
-- Pré-requis : avoir lancé scripts/dedup_main_adresse.py --execute. Sinon
-- la création de l'index échoue.

DROP INDEX main.adresse_ukey;

CREATE UNIQUE INDEX adresse_ukey ON main.adresse (
    code_postal,
    nom_commune,
    nom_voie,
    COALESCE(numero_voie, 0),
    COALESCE(repetition, '')
) NULLS NOT DISTINCT;
