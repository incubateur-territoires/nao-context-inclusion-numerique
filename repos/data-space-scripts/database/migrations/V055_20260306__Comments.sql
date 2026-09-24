-- api.carto_region
COMMENT ON COLUMN api.carto_region.code IS 'Code INSEE de la région';
COMMENT ON COLUMN api.carto_region.nom IS 'Nom de la région';
COMMENT ON COLUMN api.carto_region.nombre_lieux IS 'Nombre de lieux d''inclusion numérique de la région';

-- api.carto_departement
COMMENT ON COLUMN api.carto_departement.code IS 'Code INSEE du département';
COMMENT ON COLUMN api.carto_departement.nom IS 'Nom du département';
COMMENT ON COLUMN api.carto_departement.nombre_lieux IS 'Nombre de lieux d''inclusion numérique du département';

-- api.structures
COMMENT ON VIEW api.structures IS 'Liste de structures d''inclusion numérique (structures employeuses et lieux d''inclusion numérique).';
COMMENT ON COLUMN api.structures.nom IS 'Nom de la structure';
COMMENT ON COLUMN api.structures.siret IS 'Code SIRET de la structure. https://annuaire-entreprises.data.gouv.fr/';
COMMENT ON COLUMN api.structures.rna IS 'Identifiant du Répertoire National des Associations (RNA)';
COMMENT ON COLUMN api.structures.code_activite_principale IS 'Code NAF de l''activité principale (Base SIRENE INSEE)';
COMMENT ON COLUMN api.structures.etat_administratif IS 'Etat administratif de l''entreprise et de l''établissement (Base SIRENE INSEE)';
COMMENT ON COLUMN api.structures.denomination_sirene IS 'Dénomination de l''entreprise et de l''établissement (Base SIRENE INSEE)';
COMMENT ON COLUMN api.structures.code_categorie_juridique IS 'Catégorie juridique de l''INSEE';
COMMENT ON COLUMN api.structures.libelle_categorie_juridique IS 'Libellé de la catégorie juridique de l''INSEE';
COMMENT ON COLUMN api.structures.code_ban IS 'Code BAN de l''adresse';
COMMENT ON COLUMN api.structures.numero_voie IS 'Numero de voie';
COMMENT ON COLUMN api.structures.nom_voie IS 'Nom de voie';
COMMENT ON COLUMN api.structures.repetition IS 'Indice de repetition';
COMMENT ON COLUMN api.structures.code_postal IS 'Code postal';
COMMENT ON COLUMN api.structures.nom_commune IS 'Nom de la commune';
COMMENT ON COLUMN api.structures.code_insee IS 'Code INSEE de la commune';
COMMENT ON COLUMN api.structures.adresse IS 'Adresse complète de la structure (concaténation des éléments ci-dessus)';
COMMENT ON COLUMN api.structures.longitude IS 'Longitude en WGS84 EPSG:4326.';
COMMENT ON COLUMN api.structures.latitude IS 'Latitude en WGS84 EPSG:4326.';

-- dataviz.accompagnements
COMMENT ON COLUMN dataviz.accompagnements.thematique IS 'Thématique(s) d''accompagnement';

-- dataviz.adresse
COMMENT ON COLUMN dataviz.adresse.id IS 'Identifiant interne de l''adresse';
COMMENT ON COLUMN dataviz.adresse.clef_interop IS 'Clef d''interopérabilité de la Base Adresse Nationale en attendant de basculer complètement sur le code BAN.';
COMMENT ON COLUMN dataviz.adresse.code_ban IS 'Identifiant unique et perenne de l''adresse. En cours de déploiement à la BAN.';
COMMENT ON COLUMN dataviz.adresse.numero_voie IS 'Numero de voie';
COMMENT ON COLUMN dataviz.adresse.repetition IS 'Indice de répétition';
COMMENT ON COLUMN dataviz.adresse.nom_voie IS 'Nom de voie';
COMMENT ON COLUMN dataviz.adresse.code_postal IS 'Code postal';
COMMENT ON COLUMN dataviz.adresse.nom_commune IS 'Nom de la commune';
COMMENT ON COLUMN dataviz.adresse.code_insee IS 'Code INSEE de la commune';
COMMENT ON COLUMN dataviz.adresse.departement_code IS 'Code INSEE du département';
COMMENT ON COLUMN dataviz.adresse.departement_nom IS 'Nom du département';
COMMENT ON COLUMN dataviz.adresse.region_code IS 'Code INSEE de la région';
COMMENT ON COLUMN dataviz.adresse.region_nom IS 'Nom de la région';
COMMENT ON COLUMN dataviz.adresse.longitude IS 'Longitude en WGS84, EPSG:4326.';
COMMENT ON COLUMN dataviz.adresse.latitude IS 'Latitude en WGS84, EPSG:4326.';

-- dataviz.categorie_juridique
COMMENT ON VIEW dataviz.categorie_juridique IS 'Catégories juridiques de l''INSEE sur trois niveaux (https://www.insee.fr/fr/information/2028129)';
COMMENT ON COLUMN dataviz.categorie_juridique.code IS 'Premier niveau sur 1 digit, deuxième niveau sur 2 digits, troisième niveau sur 4 digits';
COMMENT ON COLUMN dataviz.categorie_juridique.nom IS 'Désignation de la catégorie juridique';
COMMENT ON COLUMN dataviz.categorie_juridique.niveau IS 'Niveau de la catégorie juridique (1, 2 ou 3)';
