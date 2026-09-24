-- Suppression des doublons
DELETE FROM main.personne_lieux_activites
WHERE id IN (
    SELECT t2.id
    FROM main.personne_lieux_activites t1
    INNER JOIN main.personne_lieux_activites t2
    ON t1.structure_coop_id = t2.structure_coop_id AND t1.mediateur_coop_id = t2.mediateur_coop_id
    WHERE t1.id < t2.id
);

ALTER TABLE main.personne_lieux_activites
    ADD CONSTRAINT personne_lieux_activites_ukey UNIQUE(structure_coop_id, mediateur_coop_id);


-- Suppression des doublons
DELETE FROM main.personne_structures_emplois
WHERE id IN (
    SELECT t2.id
    FROM main.personne_structures_emplois t1
    INNER JOIN main.personne_structures_emplois t2
    ON t1.structure_coop_id = t2.structure_coop_id AND t1.mediateur_coop_id = t2.mediateur_coop_id
    WHERE t1.id < t2.id
);
ALTER TABLE main.personne_structures_emplois
    ADD CONSTRAINT personne_structures_emplois_ukey UNIQUE(structure_coop_id, mediateur_coop_id);
