-- Renommage de la clef "actor" en "user_id" dans les événements MIN (V124) :
-- plus parlant, aligné sur le vocabulaire de l'app MIN.
--
--   donnee      événement complet : {"action", "entity_id", "user_id", "value"}
--
-- Pas de reprise des lignes existantes : l'app MIN émet "user_id" à partir de
-- son déploiement correspondant.

COMMENT ON COLUMN source.min__evenements.donnee IS
    'Événement complet : action, entity_id, user_id, value (create/delete : snapshot ; update : {"old", "new"} limités aux propriétés modifiées).';
