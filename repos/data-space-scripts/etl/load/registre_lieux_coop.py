"""Filet de réconciliation du registre des lieux d'inclusion coop (SEPT #1724
lot 2, #1707).

Invariant garanti : tout lieu vivant de ``coop.lieu_inclusion`` (même cluster,
vérité coop) a sa ligne d'IDENTITÉ dans ``main.lieu_inclusion`` —
``structure_coop_id``, ``nom`` (snapshot initial, colonne NOT NULL, jamais
réécrit), ``adresse_id`` résolu par ``main.trouver_ou_creer_adresse_lieu``
(V155), fraîcheur ``updated_at_coop``. Sans cette ligne, la vue d'union
``lieu_inclusion`` ne sert pas le lieu.

C'est le pendant batch du lot 1 du contrat d'écriture synchrone
(``contrat_coop_ecriture_lieux_20260820.md``) : mêmes colonnes, même fonction.
Tant que la coop n'a pas codé le lot 1, le filet fait le travail à J+1 ;
ensuite il ne trouve plus rien et sert d'alerte (un chemin d'écriture coop a
raté).

Volontairement hors périmètre : les données métier (portées par la double
écriture coop PR #615 + re-matérialisation V160), le géocodage
(la coop fournit ses coordonnées ; la fonction retrouve ou crée main.adresse à
partir de ce qu'elle transmet), la sélection par rôle (un lieu dans
coop.lieu_inclusion EST un lieu). La suppression, elle, est répercutée sur
l'ÉTAT seulement (``deleted_at``) : par le miroir métier quand la coop pose
``suppression``, par le balayage des orphelins quand le lieu coop a disparu
physiquement (SEPT #1950) — la ligne registre reste, mémoire d'identité.

Trois requêtes séquentielles dans une transaction — pas de CTE modifiante
multi-branches (toutes les branches verraient le même snapshot).
"""

from __future__ import annotations

import logging

# Prérequis de main.trouver_ou_creer_adresse_lieu (V155) : elle LÈVE une
# exception si code_insee, code_postal ou commune manquent. Les lieux coop qui
# en sont dépourvus (~120) gardent adresse_id NULL et sont comptés à part.
_ADRESSE_RESOLVABLE = """
        btrim(COALESCE(cl.code_insee, '')) <> ''
    AND btrim(COALESCE(cl.code_postal, '')) <> ''
    AND btrim(COALESCE(cl.commune, '')) <> ''
"""

_APPEL_FONCTION = """
    main.trouver_ou_creer_adresse_lieu(
        cl.adresse, cl.code_postal, cl.commune, cl.code_insee,
        cl.latitude, cl.longitude, cl.ban_id)
"""

SQL_GARDE = """
SELECT to_regclass('coop.lieu_inclusion') IS NOT NULL
   AND to_regclass('main.lieu_inclusion') IS NOT NULL
"""

# 1) Lieux coop vivants sans ligne registre → INSERT identité.
#    CASE : l'appel de fonction n'est évalué que si les prérequis sont là
#    (expression non constante → pas de pré-évaluation par le planificateur).
SQL_INSERER_MANQUANTS = f"""
INSERT INTO main.lieu_inclusion
    (structure_coop_id, nom, adresse_id, edited_by, updated_at_coop)
SELECT cl.id,
       cl.nom,
       CASE WHEN {_ADRESSE_RESOLVABLE} THEN {_APPEL_FONCTION} END,
       'coop',
       cl.modification
FROM coop.lieu_inclusion cl
WHERE cl.suppression IS NULL
  AND NOT EXISTS (SELECT 1 FROM main.lieu_inclusion r
                  WHERE r.structure_coop_id = cl.id)
"""

# 2) Lignes registre sans adresse alors que la coop peut la fournir.
SQL_COMPLETER_ADRESSES = f"""
UPDATE main.lieu_inclusion r
SET adresse_id = {_APPEL_FONCTION},
    edited_by = 'coop',
    updated_at_coop = GREATEST(r.updated_at_coop, cl.modification)
FROM coop.lieu_inclusion cl
WHERE cl.id = r.structure_coop_id
  AND cl.suppression IS NULL
  AND r.adresse_id IS NULL
  AND {_ADRESSE_RESOLVABLE}
"""

# 3) Lieux modifiés côté coop depuis la dernière prise en compte : l'adresse a
#    pu changer → re-résolution (idempotente : même clé → même adresse_id),
#    et avance de la fraîcheur. Le trigger V116 recalcule updated_at.
SQL_RAFRAICHIR = f"""
UPDATE main.lieu_inclusion r
SET adresse_id = COALESCE({_APPEL_FONCTION}, r.adresse_id),
    edited_by = 'coop',
    updated_at_coop = cl.modification
FROM coop.lieu_inclusion cl
WHERE cl.id = r.structure_coop_id
  AND cl.suppression IS NULL
  AND cl.modification > COALESCE(r.updated_at_coop, '-infinity'::timestamp)
  AND {_ADRESSE_RESOLVABLE}
"""

# 3bis) Même avance de fraîcheur pour les lieux non résolvables (sinon ils
#       ressortiraient « en retard » à chaque run).
SQL_RAFRAICHIR_SANS_ADRESSE = f"""
UPDATE main.lieu_inclusion r
SET edited_by = 'coop',
    updated_at_coop = cl.modification
FROM coop.lieu_inclusion cl
WHERE cl.id = r.structure_coop_id
  AND cl.suppression IS NULL
  AND cl.modification > COALESCE(r.updated_at_coop, '-infinity'::timestamp)
  AND NOT ({_ADRESSE_RESOLVABLE})
"""

# 4) Compteur dénormalisé servi par le référentiel : depuis la bascule V162,
#    main.lieu_inclusion est servie depuis la table — mediateurs_en_activite
#    n'est plus calculé à la lecture. Rafraîchi ici quotidiennement (fraîcheur
#    J+1 assumée pour un compteur). Pas de bump edited_by/updated_at_coop :
#    donnée dérivée, pas une édition coop.
SQL_RAFRAICHIR_COMPTEURS = """
UPDATE main.lieu_inclusion r
SET mediateurs_en_activite = calc.cnt
FROM coop.lieu_inclusion cl
LEFT JOIN LATERAL (
    SELECT count(*)::integer AS cnt
    FROM coop.mediateurs_en_activite mea
    WHERE mea.structure_id = cl.id
      AND mea.suppression IS NULL
      AND mea.fin_activite IS NULL) calc ON TRUE
WHERE cl.id = r.structure_coop_id
  AND cl.suppression IS NULL
  AND r.mediateurs_en_activite IS DISTINCT FROM calc.cnt
"""

# 5) MÉTIER — rattrapage PAR COMPARAISON DE VALEURS (pas par date : leçon du
#    2026-09-11 — un lieu créé reçoit une identité sans métier avec
#    updated_at_coop = modification, invisible à vie pour une garde par date ;
#    même angle mort pour un backfill coop sans bump). Ceinture de la fenêtre
#    entre la re-matérialisation V160 et le déploiement de la double écriture
#    coop (PR #615) ; ensuite : 0 ligne = tout va bien, >0 = un chemin
#    d'écriture coop contourne la double écriture (alerte). Mêmes expressions
#    que le backfill V160 ; listes vides : {} ≡ NULL (V166 — les écritures
#    Prisma coop posent [], non-nullable chez eux ; le côté référentiel est
#    normalisé dans la comparaison pour ne pas jouer au ping-pong avec eux) ; contact COMBINÉ clé par clé (on ne retire jamais
#    une clé comblée — l'effacement humain est porté par la double écriture,
#    pas par un batch sans contexte) ; visible = drapeau coop (aligné V162) ;
#    deleted_at miroir de la suppression.
SQL_RAFRAICHIR_METIER = """
UPDATE main.lieu_inclusion r SET
    nom              = cl.nom,
    updated_at_coop  = GREATEST(r.updated_at_coop, cl.modification),
    deleted_at       = cl.suppression,
    visible_pour_cartographie_nationale = cl.visible_pour_cartographie_nationale,
    fiche_acces_libre               = NULLIF(cl.fiche_acces_libre, ''),
    presentation_resume             = NULLIF(cl.presentation_resume, ''),
    presentation_detail             = NULLIF(cl.presentation_detail, ''),
    horaires                        = NULLIF(cl.horaires, ''),
    prise_rdv                       = NULLIF(cl.prise_rdv, ''),
    itinerance                      = NULLIF(cl.itinerance::text[], '{}')::main.itinerance[],
    services                        = NULLIF(cl.services::text[], '{}')::main.service[],
    modalites_acces                 = NULLIF(cl.modalites_acces::text[], '{}')::main.modalite_acces[],
    modalites_accompagnement        = NULLIF(cl.modalites_accompagnement::text[], '{}')::main.modalite_accompagnement[],
    publics_specifiquement_adresses = NULLIF(cl.publics_specifiquement_adresses::text[], '{}')::main.public_specifiquement_adresse[],
    prise_en_charge_specifique      = NULLIF(cl.prise_en_charge_specifique::text[], '{}')::main.prise_en_charge_specifique[],
    frais_a_charge                  = NULLIF(cl.frais_a_charge::text[], '{}')::main.frais_a_charge[],
    formations_labels               = NULLIF(cl.formations_labels::text[], '{}')::main.formation_label[],
    autres_formations_labels        = NULLIF(cl.autres_formations_labels, '{}'),
    dispositif_programmes_nationaux = NULLIF(cl.dispositif_programmes_nationaux::text[], '{}')::main.dispositif_programme_national[],
    typologies                      = NULLIF(cl.typologies::text[], '{}')::main.typologie[],
    contact = (CASE WHEN jsonb_typeof(r.contact) = 'object'
                    THEN r.contact ELSE '{}'::jsonb END)
              || jsonb_strip_nulls(jsonb_build_object(
                    'telephone', NULLIF(cl.telephone, ''),
                    'courriels',
                        CASE WHEN cl.courriels IS NOT NULL AND array_length(cl.courriels, 1) > 0
                             THEN jsonb_build_object('email', array_to_string(cl.courriels, '|'))
                             ELSE NULL::jsonb END,
                    'site_web', NULLIF(cl.site_web, '')))
FROM coop.lieu_inclusion cl
WHERE cl.id = r.structure_coop_id
  AND (r.nom, r.deleted_at, r.visible_pour_cartographie_nationale,
       r.fiche_acces_libre, r.presentation_resume, r.presentation_detail,
       r.horaires, r.prise_rdv,
       NULLIF(r.itinerance, '{}'::main.itinerance[]),
       NULLIF(r.services, '{}'::main.service[]),
       NULLIF(r.modalites_acces, '{}'::main.modalite_acces[]),
       NULLIF(r.modalites_accompagnement, '{}'::main.modalite_accompagnement[]),
       NULLIF(r.publics_specifiquement_adresses, '{}'::main.public_specifiquement_adresse[]),
       NULLIF(r.prise_en_charge_specifique, '{}'::main.prise_en_charge_specifique[]),
       NULLIF(r.frais_a_charge, '{}'::main.frais_a_charge[]),
       NULLIF(r.formations_labels, '{}'::main.formation_label[]),
       NULLIF(r.autres_formations_labels, '{}'::text[]),
       NULLIF(r.dispositif_programmes_nationaux, '{}'::main.dispositif_programme_national[]),
       NULLIF(r.typologies, '{}'::main.typologie[]),
       r.contact)
      IS DISTINCT FROM
      (cl.nom::varchar, cl.suppression, cl.visible_pour_cartographie_nationale,
       NULLIF(cl.fiche_acces_libre, '')::varchar, NULLIF(cl.presentation_resume, ''),
       NULLIF(cl.presentation_detail, ''),
       NULLIF(cl.horaires, '')::varchar, NULLIF(cl.prise_rdv, '')::varchar,
       NULLIF(cl.itinerance::text[], '{}')::main.itinerance[],
       NULLIF(cl.services::text[], '{}')::main.service[],
       NULLIF(cl.modalites_acces::text[], '{}')::main.modalite_acces[],
       NULLIF(cl.modalites_accompagnement::text[], '{}')::main.modalite_accompagnement[],
       NULLIF(cl.publics_specifiquement_adresses::text[], '{}')::main.public_specifiquement_adresse[],
       NULLIF(cl.prise_en_charge_specifique::text[], '{}')::main.prise_en_charge_specifique[],
       NULLIF(cl.frais_a_charge::text[], '{}')::main.frais_a_charge[],
       NULLIF(cl.formations_labels::text[], '{}')::main.formation_label[],
       NULLIF(cl.autres_formations_labels, '{}'),
       NULLIF(cl.dispositif_programmes_nationaux::text[], '{}')::main.dispositif_programme_national[],
       NULLIF(cl.typologies::text[], '{}')::main.typologie[],
       (CASE WHEN jsonb_typeof(r.contact) = 'object'
             THEN r.contact ELSE '{}'::jsonb END)
       || jsonb_strip_nulls(jsonb_build_object(
             'telephone', NULLIF(cl.telephone, ''),
             'courriels',
                 CASE WHEN cl.courriels IS NOT NULL AND array_length(cl.courriels, 1) > 0
                      THEN jsonb_build_object('email', array_to_string(cl.courriels, '|'))
                      ELSE NULL::jsonb END,
             'site_web', NULLIF(cl.site_web, ''))))
"""

# 7) Orphelins (SEPT #1950, piège n° 8) : ligne référentiel vivante dont le
#    structure_coop_id ne résout plus dans coop.lieu_inclusion — suppression
#    PHYSIQUE côté coop sans écho (job de réconciliation carto retiré le
#    09/09/2026, script SQL, fusion antérieure à retirerDuRegistre…). Le
#    miroir métier ci-dessus ne voit que les lieux coop qui existent encore ;
#    ce balayage couvre tout chemin non instrumenté. Seul l'ÉTAT bascule : la
#    ligne reste, identité conservée (structure_coop_id), date honnête
#    (updated_at_coop = now() : un vrai changement, constaté aujourd'hui).
#    Idempotent (deleted_at IS NULL).
SQL_RETIRER_ORPHELINS = """
UPDATE main.lieu_inclusion r
SET deleted_at = now(),
    edited_by = 'coop',
    updated_at_coop = now()
WHERE r.structure_coop_id IS NOT NULL
  AND r.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM coop.lieu_inclusion cl WHERE cl.id = r.structure_coop_id)
"""

SQL_BILAN = f"""
SELECT count(*) FILTER (WHERE r.id IS NULL)                              AS sans_registre,
       count(*) FILTER (WHERE r.id IS NOT NULL AND r.adresse_id IS NULL) AS sans_adresse,
       count(*) FILTER (WHERE r.id IS NOT NULL AND r.adresse_id IS NULL
                          AND NOT ({_ADRESSE_RESOLVABLE}))             AS sans_adresse_non_resolvable,
       count(*)                                                          AS lieux_vivants
FROM coop.lieu_inclusion cl
LEFT JOIN main.lieu_inclusion r ON r.structure_coop_id = cl.id
WHERE cl.suppression IS NULL
"""


def reconcilier_registre_lieux(conn) -> dict[str, int] | None:
    """Exécute le filet sur ``conn`` (psycopg2, autocommit off) et commit.

    Retourne les compteurs, ou None si le schéma coop / le registre est
    absent (CI, base neuve : no-op, même garde que V153/V155/V158).
    """
    with conn.cursor() as cur:
        cur.execute(SQL_GARDE)
        if not cur.fetchone()[0]:
            logging.info(
                "Filet registre lieux : schéma coop ou registre absent — no-op."
            )
            return None

        cur.execute(SQL_INSERER_MANQUANTS)
        inseres = cur.rowcount
        cur.execute(SQL_COMPLETER_ADRESSES)
        adresses_completees = cur.rowcount
        cur.execute(SQL_RAFRAICHIR)
        rafraichis = cur.rowcount
        cur.execute(SQL_RAFRAICHIR_SANS_ADRESSE)
        rafraichis_sans_adresse = cur.rowcount
        cur.execute(SQL_RAFRAICHIR_COMPTEURS)
        compteurs_rafraichis = cur.rowcount
        cur.execute(SQL_RAFRAICHIR_METIER)
        metier_rafraichi = cur.rowcount
        cur.execute(SQL_RETIRER_ORPHELINS)
        orphelins_retires = cur.rowcount
        cur.execute(SQL_BILAN)
        sans_registre, sans_adresse, non_resolvable, vivants = cur.fetchone()
    conn.commit()

    bilan = {
        "inseres": inseres,
        "adresses_completees": adresses_completees,
        "rafraichis": rafraichis,
        "rafraichis_sans_adresse": rafraichis_sans_adresse,
        "compteurs_rafraichis": compteurs_rafraichis,
        "metier_rafraichi": metier_rafraichi,
        "orphelins_retires": orphelins_retires,
        "lieux_vivants": vivants,
        "reste_sans_registre": sans_registre,
        "reste_sans_adresse": sans_adresse,
        "reste_sans_adresse_non_resolvable": non_resolvable,
    }
    logging.info("Filet registre lieux coop : %s", bilan)
    if sans_registre:
        # Invariant violé après passage : ne doit jamais arriver (INSERT sans
        # filtre autre que l'existence) — remonter fort.
        logging.error(
            "Filet registre lieux : %s lieux coop vivants toujours sans ligne "
            "registre après réconciliation.",
            sans_registre,
        )
    if orphelins_retires:
        # Un lieu coop a été supprimé PHYSIQUEMENT sans écho au référentiel :
        # chemin non instrumenté côté coop, à signaler (contrat #1724).
        logging.warning(
            "Filet registre lieux : %s inscriptions orphelines (structure_coop_id "
            "sans lieu coop) retirées — deleted_at posé.",
            orphelins_retires,
        )
    if sans_adresse - non_resolvable:
        logging.warning(
            "Filet registre lieux : %s lieux résolvables restent sans adresse "
            "(la fonction a renvoyé NULL ?).",
            sans_adresse - non_resolvable,
        )
    return bilan
