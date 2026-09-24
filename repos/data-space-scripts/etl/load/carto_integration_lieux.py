"""SQL de la tâche `integration_lieux` du carto-dag (SEPT #1950).

Le corps de la transaction qui intègre le fichier national dans le référentiel
`main.lieu_inclusion` vit ici, importable par le DAG (`carto-dag-import.py`) ET
par la spécification exécutable `tests/carto/test_cycle_de_vie_lieux.py`, qui
l'exécute tel quel sur base, en transaction annulée, cas par cas
(`tests/carto/cas_cycle_de_vie_lieux.yml`).

Doctrine « l'état d'un lieu n'est pas une donnée »
(docs/cycle-de-vie-lieux-personnes.md §1.3) :

- l'ÉTAT (`visible_pour_cartographie_nationale`, `deleted_at`) appartient aux
  outils de gestion — la Coop (`structure_coop_id`) et MIN (`updated_at_min`).
  Le fichier national ne le pilote que pour les lignes EXTERNES, que personne
  n'a jamais gérées : présent au fichier = allumé, absent = éteint et
  déréférencé. Il ne rallume jamais un lieu supprimé ;
- les DONNÉES (nom, adresse, horaires, services, contact…) suivent « le plus
  frais gagne » : aucune source n'est supérieure à une autre. Une ligne gérée
  par MIN continue de recevoir les données du fichier national s'il est plus
  frais ; une ligne coop n'est jamais écrite par le flux (ses données viennent
  de la double écriture coop, cf. §2.3).

Aucun import ici : le DAG construit son SQL au parse, ce module doit rester
trivial à charger.
"""

# Ligne EXTERNE = ni coop, ni jamais touchée par MIN. Seule population dont le
# fichier national pilote l'état.
GARDE_LIGNE_EXTERNE = "l.structure_coop_id IS NULL AND l.updated_at_min IS NULL"

CONTACT_JSONB = """jsonb_strip_nulls(jsonb_build_object(
                        'telephone', NULLIF(m.telephone, ''),
                        'courriels', CASE WHEN m.courriels IS NOT NULL AND m.courriels <> ''
                            THEN jsonb_build_object('email', m.courriels) ELSE NULL END,
                        'site_web', NULLIF(m.site_web, '')))"""

# Colonnes de DONNÉES écrites par le flux (UPDATE des lignes existantes).
# Refonte phase 4 : carto n'alimente que des LIEUX D'INCLUSION ; les attributs
# SIRENE appartiennent à structure_administrative. Casts ::main.<enum>[] (V122) :
# string_to_array renvoie text[] et Postgres refuse text[] -> enum[] sans cast
# explicite (fail-fast voulu sur une valeur hors enum).
# Aucune colonne d'ÉTAT ici : la visibilité des lignes existantes ne passe que
# par SQL_REACTIVER_PRESENTS / SQL_DESACTIVER_ABSENTS.
SET_DONNEES_CARTO = f"""
                    nom = m.nom,
                    adresse_id = COALESCE(m.adresse_id, l.adresse_id),
                    typologies = string_to_array(m.typologie, '|')::main.typologie[],
                    presentation_resume = m.presentation_resume::text,
                    presentation_detail = m.presentation_detail,
                    contact = {CONTACT_JSONB},
                    horaires = m.horaires,
                    prise_rdv = m.prise_rdv,
                    services = string_to_array(m.services, '|')::main.service[],
                    publics_specifiquement_adresses = string_to_array(m.publics_specifiquement_adresses, '|')::main.public_specifiquement_adresse[],
                    prise_en_charge_specifique = string_to_array(m.prise_en_charge_specifique, '|')::main.prise_en_charge_specifique[],
                    frais_a_charge = string_to_array(m.frais_a_charge, '|')::main.frais_a_charge[],
                    dispositif_programmes_nationaux = string_to_array(m.dispositif_programmes_nationaux, '|')::main.dispositif_programme_national[],
                    formations_labels = string_to_array(m.formations_labels, '|')::main.formation_label[],
                    autres_formations_labels = string_to_array(m.autres_formations_labels, '|'),
                    itinerance = string_to_array(m.itinerance, '|')::main.itinerance[],
                    modalites_acces = string_to_array(m.modalites_acces, '|')::main.modalite_acces[],
                    modalites_accompagnement = string_to_array(m.modalites_accompagnement, '|')::main.modalite_accompagnement[],
                    fiche_acces_libre = m.fiche_acces_libre,
                    source = m.source,
                    edited_by = 'carto',
                    updated_at_carto = m.date_maj::timestamp"""

# Garde de fraîcheur : on n'écrase les données que si la date de màj annoncée
# par la source (staging.carto__structures.date_maj) est STRICTEMENT plus
# récente que la fraîcheur globale du lieu (updated_at = GREATEST
# carto/coop/min, cf V116). Une édition MIN ou coop plus récente bloque donc
# l'écrasement par un flux carto périmé. date_maj est `date NOT NULL` dans le
# silver (V136) : pas de cas NULL/vide côté source.
WHERE_PLUS_FRAIS = """
                  AND m.date_maj::timestamp
                      > COALESCE(l.updated_at, '-infinity'::timestamp)"""

# 1b) Réactivation : un lieu EXTERNE présent au fichier redevient visible
#     (symétrique de la désactivation des absents). Jamais une ligne gérée
#     par un outil (coop, MIN) — sa visibilité est SA décision — et jamais un
#     lieu supprimé.
SQL_REACTIVER_PRESENTS = f"""
            UPDATE main.lieu_inclusion l
            SET visible_pour_cartographie_nationale = TRUE,
                edited_by = 'carto'
            FROM _match m
            WHERE l.structure_cartographie_nationale_id = m.carto_id
              AND {GARDE_LIGNE_EXTERNE}
              AND l.deleted_at IS NULL
              AND l.visible_pour_cartographie_nationale IS DISTINCT FROM TRUE;"""

# 2) Données par carto_id (cas nominal ET lieux tout juste rattachés en 1),
#    sous garde de fraîcheur. Lignes non coop : un lieu coop n'est jamais
#    écrit par le flux carto (SEPT #1724 étape 4) — ses données arrivent de la
#    double écriture coop. Une ligne gérée par MIN reçoit, elle, les données
#    du flux s'il est plus frais : aucune source n'est supérieure.
SQL_RAFRAICHIR_DONNEES = f"""
            UPDATE main.lieu_inclusion l
            SET {SET_DONNEES_CARTO}
            FROM _match m
            WHERE l.structure_cartographie_nationale_id = m.carto_id
              AND l.structure_coop_id IS NULL
            {WHERE_PLUS_FRAIS};"""


def sql_desactiver_absents(run_id: str) -> str:
    """Absent du fichier = éteint et déréférencé — lignes EXTERNES uniquement.

    La vie d'un lieu géré par un outil (coop, MIN) ne dépend jamais de sa
    présence au fichier national : sa visibilité = son drapeau, son carto_id
    est conservé (continuité si le record revient). Sans cette restriction,
    le déréférencement nocturne ferait du ping-pong avec l'interrupteur de
    partage écrit par la coop (PR coop #615) ou le masquage fait dans MIN.
    """
    return f"""
            UPDATE main.lieu_inclusion l
            SET visible_pour_cartographie_nationale = FALSE,
                structure_cartographie_nationale_id = NULL
            WHERE {GARDE_LIGNE_EXTERNE}
              AND (l.structure_cartographie_nationale_id IS NOT NULL
                   OR l.visible_pour_cartographie_nationale IS TRUE)
              AND NOT EXISTS (
                SELECT 1 FROM staging.carto__structures c
                WHERE c.run_id = '{run_id}'
                  AND c.id = l.structure_cartographie_nationale_id
            );"""


def sql_integration_lieux(run_id: str) -> str:
    """Corps de la transaction `integration_lieux` pour un run donné.

    `run_id` est inséré tel quel dans le SQL : le DAG passe le template Jinja
    `{{ run_id }}` (rendu par Airflow à l'exécution), les tests un identifiant
    littéral. Sans BEGIN/COMMIT : le DAG les ajoute, les tests restent dans
    leur transaction (ROLLBACK).

    Stratégie de match (refonte phase 4, garde de fraîcheur 2026-07) :
      0)  matérialisation des correspondances (_match) ;
      0b) double match carto+coop sur deux lignes : la ligne coop reçoit le carto_id ;
      1)  rattachement carto_id par structure_coop_id (lien seul, hors garde) ;
      1b) réactivation des lieux EXTERNES présents au flux ;
      2)  UPDATE des données par carto_id, si date_maj source > updated_at ;
      3)  INSERT nouveau lieu (ni carto_id ni coop_id ne matchent) — naît allumé ;
      4)  désactivation des lieux EXTERNES absents du flux.
    """
    return f"""
            -- 0) Matérialiser les correspondances (calculé une seule fois sur le snapshot initial)
            CREATE TEMP TABLE _match ON COMMIT DROP AS
            WITH incoming AS (
                SELECT
                    c.id::text AS carto_id,
                    c.source::text AS source,
                    -- structure_coop_id du flux, sinon UUID coop extrait de l'id.
                    -- Quand mednum-cli fusionne un lieu Coop avec une autre source,
                    -- l'id devient composite (ex. « Coop-numérique_<uuid>__France-Services_789 »)
                    -- et le champ structure_coop_id arrive vide → sans extraction,
                    -- chaque lieu fusionné créait un doublon du lieu coop existant
                    -- (fiche visible vide + fiche coop cachée portant les activités).
                    -- Les ids sont composés de segments séparés par « __ » : seul un
                    -- segment strictement « Coop-numérique_<uuid> » (début d'id ou
                    -- précédé de « __ ») est un id coop — « Numi_Coop-numérique_<uuid> »
                    -- est un id Numi, jamais extrait. Au plus un segment coop par id.
                    COALESCE(
                        c.structure_coop_id::uuid,
                        (regexp_match(c.id, '(?:^|__)Coop-numérique_([0-9a-f]{{8}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{12}})(?:__|$)'))[1]::uuid
                    ) AS structure_coop_id,
                    c.nom, c.typologie, c.presentation_resume, c.presentation_detail,
                    -- Lookup adresse par la clé naturelle de main.adresse :
                    -- rattrape la ligne insérée depuis les coords mednum-cli
                    -- par l'INSERT de integration_adresses. La regex doit
                    -- rester strictement alignée avec celle de
                    -- integration_adresses. (L'ancien lookup principal par
                    -- clef_interop était mort : ban_clef_interop toujours NULL
                    -- depuis la bascule sur le fichier national.)
                    (SELECT a.id FROM main.adresse a
                     WHERE a.code_postal = c.code_postal
                       AND a.nom_commune = c.commune
                       AND a.nom_voie IS NOT DISTINCT FROM
                           initcap((regexp_match(c.adresse, '^(?:\\d+\\s+)?(.*)$'))[1])
                       AND COALESCE(a.numero_voie, 0) = COALESCE(
                           (regexp_match(c.adresse, '^(\\d+)\\s*(bis|ter|quater|quinquies)?\\s+(.*)$', 'i'))[1]::smallint,
                           0)
                       AND COALESCE(a.repetition, '') = ''
                     LIMIT 1) AS adresse_id,
                    c.telephone, c.courriels, c.site_web, c.horaires, c.prise_rdv,
                    c.services, c.publics_specifiquement_adresses,
                    c.prise_en_charge_specifique, c.frais_a_charge,
                    c.dispositif_programmes_nationaux, c.formations_labels,
                    c.autres_formations_labels, c.itinerance,
                    c.modalites_acces, c.modalites_accompagnement, c.fiche_acces_libre,
                    c.date_maj
                FROM staging.carto__structures c
                WHERE c.run_id = '{run_id}'
                  AND c.id <> ''
                  -- Doit rester aligné avec integration_adresses : on skippe les
                  -- adresses dont le préfixe numérique dépasse smallint (32767),
                  -- sinon le cast ::smallint du fallback ci-dessous explose.
                  AND COALESCE((regexp_match(c.adresse, '^(\\d+)'))[1]::int, 0) <= 32767
            )
            SELECT
                i.*,
                l_coop.id  AS id_by_coop,
                l_carto.id AS id_by_carto,
                -- Un même coop_id peut apparaître plusieurs fois dans l'incoming.
                -- On ne garde que la première ligne (par carto_id) pour respecter
                -- la contrainte UNIQUE sur lieu_inclusion.structure_coop_id.
                row_number() OVER (
                    PARTITION BY i.structure_coop_id ORDER BY i.carto_id
                ) AS coop_rn,
                -- Coop_id présent dans l'incoming mais inconnu en base → flag warn
                (i.structure_coop_id IS NOT NULL AND l_coop.id IS NULL) AS coop_id_unknown
            FROM incoming i
            LEFT JOIN main.lieu_inclusion l_coop
                ON i.structure_coop_id IS NOT NULL
               AND l_coop.structure_coop_id = i.structure_coop_id
            LEFT JOIN main.lieu_inclusion l_carto
                ON l_carto.structure_cartographie_nationale_id = i.carto_id;

            -- 0b) Double match carto+coop sur deux lieux différents : le record
            --     incoming matche par carto_id une ligne A ET par coop_id une
            --     ligne B. Depuis la refonte #1724 la ligne coop (B) est
            --     l'identité qui fait foi (la vue et les activités s'y
            --     rattachent par structure_coop_id) : c'est ELLE qui reçoit le
            --     carto_id ; la ligne carto (A) le perd et, n'étant plus dans
            --     le flux, est désactivée par la désactivation des absents en
            --     fin de transaction. Ordre imposé par les contraintes UNIQUE
            --     (non déférables) : retirer la clef avant de la poser.
            UPDATE main.lieu_inclusion la
            SET structure_cartographie_nationale_id = NULL, edited_by = 'carto'
            FROM _match m
            WHERE m.id_by_carto IS NOT NULL AND m.id_by_coop IS NOT NULL
              AND m.id_by_carto <> m.id_by_coop AND la.id = m.id_by_carto;

            UPDATE main.lieu_inclusion lb
            SET structure_cartographie_nationale_id = m.carto_id, edited_by = 'carto'
            FROM _match m
            WHERE m.id_by_carto IS NOT NULL AND m.id_by_coop IS NOT NULL
              AND m.id_by_carto <> m.id_by_coop AND lb.id = m.id_by_coop
              AND m.coop_rn = 1
              AND lb.structure_cartographie_nationale_id IS DISTINCT FROM m.carto_id;

            -- 1) Rattachement du carto_id aux lieux matchés par coop_id.
            --    Lien d'identifiant TOUJOURS posé, hors garde de fraîcheur :
            --    c'est du lien, pas de la donnée métier — sans lui le lieu
            --    resterait durablement invisible d'api.carto.
            UPDATE main.lieu_inclusion l
            SET structure_cartographie_nationale_id = m.carto_id,
                edited_by = 'carto'
            FROM _match m
            WHERE m.structure_coop_id IS NOT NULL
              AND l.structure_coop_id = m.structure_coop_id
              AND m.id_by_carto IS NULL
              AND l.structure_cartographie_nationale_id IS DISTINCT FROM m.carto_id;

            -- 1b) Réactivation des lieux EXTERNES présents au flux (ÉTAT).
            {SQL_REACTIVER_PRESENTS}

            -- 2) DONNÉES par carto_id, sous garde de fraîcheur.
            {SQL_RAFRAICHIR_DONNEES}

            -- 3) INSERT nouveaux lieux (ni carto_id ni coop_id ne matchent).
            --    Une ligne externe neuve naît allumée (TRUE positionnel).
            --    Si coop_id inconnu, on logge un warn JSONB (cas inattendu :
            --    la coop devrait pré-exister tout coop_id qu'on reçoit ici).
            INSERT INTO main.lieu_inclusion (
                structure_cartographie_nationale_id, visible_pour_cartographie_nationale,
                structure_coop_id, nom, typologies,
                presentation_resume, presentation_detail, adresse_id,
                contact, horaires, prise_rdv, services,
                publics_specifiquement_adresses, prise_en_charge_specifique,
                frais_a_charge, dispositif_programmes_nationaux,
                formations_labels, autres_formations_labels,
                itinerance, modalites_acces, modalites_accompagnement,
                fiche_acces_libre, source, edited_by, updated_at_carto, import_warnings
            )
            SELECT
                m.carto_id, TRUE, m.structure_coop_id, m.nom,
                string_to_array(m.typologie, '|')::main.typologie[],
                m.presentation_resume::text, m.presentation_detail, m.adresse_id,
                {CONTACT_JSONB},
                m.horaires, m.prise_rdv,
                string_to_array(m.services, '|')::main.service[],
                string_to_array(m.publics_specifiquement_adresses, '|')::main.public_specifiquement_adresse[],
                string_to_array(m.prise_en_charge_specifique, '|')::main.prise_en_charge_specifique[],
                string_to_array(m.frais_a_charge, '|')::main.frais_a_charge[],
                string_to_array(m.dispositif_programmes_nationaux, '|')::main.dispositif_programme_national[],
                string_to_array(m.formations_labels, '|')::main.formation_label[],
                string_to_array(m.autres_formations_labels, '|'),
                string_to_array(m.itinerance, '|')::main.itinerance[],
                string_to_array(m.modalites_acces, '|')::main.modalite_acces[],
                string_to_array(m.modalites_accompagnement, '|')::main.modalite_accompagnement[],
                -- date_maj source (pas now()) : la fraîcheur affichée reflète le
                -- vrai changement métier côté source (date NOT NULL dans le silver).
                m.fiche_acces_libre, m.source, 'carto', m.date_maj::timestamp,
                CASE WHEN m.coop_id_unknown THEN
                    jsonb_build_object(
                        'carto:' || to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS'),
                        jsonb_build_object(
                            'level', 'warn',
                            'code', 'unknown_coop_id',
                            'message', 'carto a injecté un nouveau lieu avec un coop_id inconnu en base',
                            'coop_id', m.structure_coop_id
                        )
                    )
                ELSE NULL END AS import_warnings
            FROM _match m
            WHERE m.id_by_carto IS NULL
              AND m.id_by_coop IS NULL
              -- garde coop_id côté incoming : si plusieurs lignes incoming partagent
              -- le même coop_id, on ne garde que la première (la contrainte UNIQUE
              -- bloquerait sinon).
              AND (m.structure_coop_id IS NULL OR m.coop_rn = 1);

            -- NB : l'ancien backfill UPDATE import.carto SET lieu_inclusion_id
            -- (seule FK import → main de la base) est supprimé avec la table de
            -- landing : le silver reste en sens unique (bronze → silver → gold).
            -- L'association est déjà donnée par
            -- main.lieu_inclusion.structure_cartographie_nationale_id = c.id.

            -- 4) Désactivation des lieux EXTERNES absents du flux (ÉTAT).
            {sql_desactiver_absents(run_id)}
    """
