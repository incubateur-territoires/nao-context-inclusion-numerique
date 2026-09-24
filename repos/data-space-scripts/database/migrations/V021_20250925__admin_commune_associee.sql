CREATE UNLOGGED TABLE import.ign_commune_associee_ou_deleguee (
    id CHARACTER VARYING(24) NOT NULL,
    geom GEOMETRY (MULTIPOLYGON, 4326) NOT NULL,
    nom character varying(255) NOT NULL,
    nom_m character varying(255) NOT NULL,
    insee_cad character varying(5) NOT NULL, -- Insee de la commune associée ou déléguée
    insee_com character varying(5) NOT NULL, -- Insee de la commune de rattachement
    nature character varying(4) NOT NULL,
    population integer
);

ALTER TABLE admin.commune 
    ADD COLUMN code_insee_cr character varying(5) DEFAULT NULL;

COMMENT ON COLUMN admin.commune.statut IS 'Les communes peuvent avoir le statut : Capitale d''état, Préfecture de région, Préfecture, Sous-préfecture, Commune simple,  Arrondissement, Commune associée, Commune déléguée';
COMMENT ON COLUMN admin.commune.code_insee_cr IS 'Code insee de la commune de rattachement';
