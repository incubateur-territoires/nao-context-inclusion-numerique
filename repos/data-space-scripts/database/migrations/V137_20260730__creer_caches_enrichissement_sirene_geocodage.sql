-- Caches d'enrichissement (fiche 05, problème ouvert fiche 08) : le résultat
-- des appels aux APIs externes SIRENE (INSEE) et géocodage (BAN / Géoplateforme
-- IGN) est matérialisé dans des tables de référence adressées par la CLÉ
-- D'ENTRÉE de l'appel — plus par flux. Tout flux consulte le cache avant
-- d'appeler l'API (etl/enrichment_cache.py) et l'alimente en write-through.
--
-- Contrairement au silver de flux (TRUNCATE + INSERT par run), ces tables sont
-- des référentiels ACCUMULÉS : UPSERT par clé, jamais tronquées. Fraîcheur par
-- enriched_at (TTL appliqué à la lecture, 4 mois — aligné sur le gate
-- last_sirene_enrich_at existant d'AC/coop). Seuls les résultats UTILES sont
-- cachés (établissement trouvé / géocodage valide) : un échec ou une absence
-- reste re-tenté à chaque run, comme avant.
--
-- Sens unique bronze -> silver -> gold : aucune FK vers main.
-- Grants : couverts par les ALTER DEFAULT PRIVILEGES du schéma staging (V128).

-- Clé : SIRET normalisé (14 chiffres, zfill). Valeurs : sortie parsée de
-- SireneBatch (texte brut de l'API ; date_creation_sirene reste TEXT pour
-- restituer à l'identique la valeur que produirait un appel direct).
CREATE TABLE staging.sirene__cache (
    siret                     TEXT        PRIMARY KEY,
    run_id                    TEXT        NOT NULL,
    enriched_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    etat_administratif        TEXT,
    code_activite_principale  TEXT,
    categorie_juridique       TEXT,
    denomination_sirene       TEXT,
    adresse_sirene            TEXT,
    code_insee_sirene         TEXT,
    code_postal_sirene        TEXT,
    date_creation_sirene      TEXT,
    tranche_effectifs_sirene  TEXT
);

-- Clé : le triplet exactement soumis à l'API (adresse construite + filtres
-- citycode/postcode, '' si absents — le retry carto sans code_insee est donc
-- une entrée distincte). Valeurs : sortie du core BAN
-- (etl/core/ban.py:transformer_reponses), geocodage_valide = TRUE implicite.
CREATE TABLE staging.geocodage__cache (
    adresse             TEXT             NOT NULL,
    code_insee          TEXT             NOT NULL DEFAULT '',
    code_postal         TEXT             NOT NULL DEFAULT '',
    run_id              TEXT             NOT NULL,
    enriched_at         TIMESTAMPTZ      NOT NULL DEFAULT now(),
    code_insee_geocode  TEXT,
    numero_voie         TEXT,
    nom_voie            TEXT,
    nom_commune         TEXT,
    code_postal_geocode TEXT,
    longitude           DOUBLE PRECISION,
    latitude            DOUBLE PRECISION,
    score_geocodage     DOUBLE PRECISION,
    label_geocodage     TEXT,
    geom                TEXT,
    clef_interop        TEXT,
    code_ban            TEXT,
    PRIMARY KEY (adresse, code_insee, code_postal)
);
