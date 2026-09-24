Pseudonymisation des données
===

Pour les besoins de dev de l'équipe MIN, il est nécessaire de disposer de données pour travailler en local.

Ce processus vise à pseudonymiser les données contenues en base.

Le principe est simple :
- les `noms` et `prénoms` sont remplacés par des noms et prénoms issus de l'opendata et tirés au hasard,
- les adresses emails sont composées de ces noms et prénoms (pour avoir une cohérence au niveau entité) et d'un nom de domaine tiré au hasard dans une liste,
si l'entité n'a pas de colonnes `nom`, `prénom`, des valeurs sont prise au hasard,
- les numéros de téléphone sont générés aléatoirement.

Toute cette logique et données générées sont dans un schéma `pseudonymisation`.

Les fonctions :
- `pseudonymisation.generate_phone_number()` pattern : '+33' || RANDOM(1, 7)::INT || RANDOM() * 90000000) + 10000000)::INT
- `pseudonymisation.generate_prenom()`
- `pseudonymisation.generate_nom()`
- `pseudonymisation.generate_email(prenom VARCHAR, nom VARCHAR)`

# Le schéma `pseudonymisation`

## Création du schéma

```sql
CREATE SCHEMA pseudonymisation;
```


## Les tables de données noms et prénoms

```sql
CREATE TABLE pseudonymisation.prenom(
    value VARCHAR(255) PRIMARY KEY
);

CREATE TABLE pseudonymisation.nom(
    value VARCHAR(255) PRIMARY KEY
);
```

Ces deux tables sont peuplées grâce aux données publiées en Opendata sur DataGouv par Christian Quest
https://www.data.gouv.fr/fr/datasets/liste-de-prenoms-et-patronymes/
limitées aux ~ 1.000 premières valeurs et la première colonne.

### Chargement des données

```sh
psql -d dataspace_xxx -c "\COPY pseudonymisation.prenom FROM 'prenom.csv' CSV HEADER;"
psql -d dataspace_xxx -c "\COPY pseudonymisation.nom FROM 'patronymes.csv' CSV HEADER;"
```


## Les fonctions de génération

```sql
CREATE OR REPLACE FUNCTION pseudonymisation.generate_phone_number()
RETURNS VARCHAR AS $$
DECLARE
    v_phone_number VARCHAR(15);
BEGIN
    -- Générer un numéro de téléphone aléatoire
    v_phone_number := '+33' ||
                   (FLOOR(RANDOM() * 7) + 1)::INT ||
                   (FLOOR(RANDOM() * 90000000) + 10000000)::INT;
    RETURN v_phone_number;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION pseudonymisation.generate_prenom()
RETURNS VARCHAR AS $$
BEGIN
    RETURN (SELECT value FROM pseudonymisation.prenom ORDER BY RANDOM() LIMIT 1);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION pseudonymisation.generate_nom()
RETURNS VARCHAR AS $$
BEGIN
    RETURN (SELECT value FROM pseudonymisation.nom ORDER BY RANDOM() LIMIT 1);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION pseudonymisation.generate_email(prenom VARCHAR, nom VARCHAR)
RETURNS VARCHAR AS $$
DECLARE
    domains VARCHAR[] := ARRAY['bbox.fr', 'free.fr', 'aliceadsl.fr', 'libertysurf.fr', 'online.fr', 'freesbee.fr', 'alicepro.fr', 'worldonline.fr', 'caramail.com', 'laposte.net', 'hotmail.fr', 'live.fr', 'msn.fr', 'outlook.fr', 'numericable.fr', 'orange.fr', 'wanadoo.fr', 'sfr.fr', 'neuf.fr', '9online.fr', '9business.fr', 'cegetel.net', 'club-internet.fr', 'voila.fr', 'yahoo.fr'];
    domain VARCHAR(50);
    email VARCHAR(100);
BEGIN
    -- Choisir un domaine aléatoire dans la liste
    domain := domains[FLOOR(RANDOM() * ARRAY_LENGTH(domains, 1) + 1)::INT];

    -- Construire l'adresse email
    email := prenom || '.' || nom || '@' || domain;

    RETURN email;
END;
$$ LANGUAGE plpgsql;
```

## Génération des données pseudonymisées

Une fois la structure créée, les données chargées, il est possible d'utiliser les fonctions.

Exemple :

```sql
SELECT generate_series(1, 5, 1) AS id,
pseudonymisation.generate_nom() AS nom,
pseudonymisation.generate_prenom() AS prenom,
pseudonymisation.generate_phone_number() AS telephone;

 id |   nom   |  prenom   |  telephone
----+---------+-----------+--------------
  1 | GIL     | SALVATORE | +33280440586
  2 | SOLER   | ABDALLAH  | +33394627647
  3 | GILLES  | NICOLE    | +33344953915
  4 | BABIN   | PEGGY     | +33241338279
  5 | DUCROCQ | JULIEN    | +33347086918
(5 lignes)
```


### Pour le schéma `main`

La logique est de récupérer les enregistrements présents dans les tables, donc les données réelles, mais de remplacer les données identifiantes comme : nom, prénom, adresse email, numéro de téléphone.

```sql
DROP TABLE IF EXISTS pseudonymisation.main_personne;
CREATE TABLE pseudonymisation.main_personne AS (
    WITH sub AS (
        SELECT id,
        pseudonymisation.generate_prenom() AS prenom,
        pseudonymisation.generate_nom() AS nom,
        contact,
        structure_id,
        aidant_connect_id,
        conseiller_numerique_id,
        cn_pg_id,
        coop_id,
        is_coordinateur,
        is_mediateur,
        is_active_ac,
        formation_fne_ac,
        profession_ac,
        nb_accompagnements_ac,
        created_at,
        updated_at
        FROM main.personne
    )
    SELECT id, prenom, nom,
    jsonb_build_object(
        'courriels', jsonb_build_object('mail_pro', pseudonymisation.generate_email(prenom, nom)),
        'telephone', pseudonymisation.generate_phone_number()
    ) AS contact,
    structure_id, aidant_connect_id, conseiller_numerique_id, cn_pg_id, coop_id, is_coordinateur, is_mediateur, is_active_ac, formation_fne_ac, profession_ac, nb_accompagnements_ac, created_at, updated_at
    FROM sub
);


DROP TABLE IF EXISTS pseudonymisation.main_structure;
CREATE TABLE pseudonymisation.main_structure AS (
    SELECT
    id,
    structure_coop_id,
    structure_ac_id,
    structure_tp_id,
    nom,
    denomination_sirene,
    siret,
    rna,
    adresse_id,
    jsonb_strip_nulls(jsonb_build_object(
        'telephone', pseudonymisation.generate_phone_number(),
        'courriels', ARRAY[pseudonymisation.generate_email(pseudonymisation.generate_prenom(), pseudonymisation.generate_nom())]
    )) AS contact,
    etat_administratif,
    code_activite_principale,
    categorie_juridique,
    nb_mandats_ac,
    publique,
    structure_cartographie_nationale_id,
    visible_pour_cartographie_nationale,
    typologies,
    presentation_resume,
    presentation_detail,
    horaires,
    prise_rdv,
    structure_parente,
    services,
    publics_specifiquement_adresses,
    prise_en_charge_specifique,
    frais_a_charge,
    dispositif_programmes_nationaux,
    formations_labels,
    autres_formations_labels,
    itinerance,
    modalites_acces,
    modalites_accompagnement,
    mediateurs_en_activite,
    emplois,
    source,
    last_sirene_enrich_at,
    created_at,
    updated_at
    FROM main.structure
);
```


### Pour le schéma `min`

```sql
DROP TABLE IF EXISTS pseudonymisation.min_utilisateur;
CREATE TABLE pseudonymisation.min_utilisateur AS (
    WITH sub AS (
        SELECT id,
        pseudonymisation.generate_nom() AS nom,
        pseudonymisation.generate_prenom() AS prenom,
        role,
        pseudonymisation.generate_phone_number() AS telephone,
        date_de_creation,
        departement_code,
        derniere_connexion,
        invite_le,
        is_super_admin,
        is_supprime,
        region_code,
        gen_random_uuid() AS sso_id,
        structure_id,
        groupement_id
        FROM min.utilisateur
    )
    SELECT id,
        nom,
        prenom,
        role,
        telephone,
        date_de_creation,
        departement_code,
        derniere_connexion,
        pseudonymisation.generate_email(prenom, nom) AS email_de_contact,
        invite_le,
        is_super_admin,
        is_supprime,
        region_code,
        pseudonymisation.generate_email(prenom, nom) AS sso_email,
        sso_id,
        structure_id,
        groupement_id
    FROM sub
);


-- Pour les éventuels doublons
UPDATE pseudonymisation.min_utilisateur
SET sso_email = pseudonymisation.generate_email(pseudonymisation.generate_nom(), pseudonymisation.generate_prenom())
WHERE id IN (
    select MAX(id)
    from pseudonymisation.min_utilisateur
    group by sso_email
    having count(*) > 1

DROP TABLE IF EXISTS pseudonymisation.min_membre;
CREATE TABLE pseudonymisation.min_membre AS (
    SELECT id,
    type,
    statut,
    pseudonymisation.generate_email(pseudonymisation.generate_prenom(), pseudonymisation.generate_nom()) AS contact,
    pseudonymisation.generate_email(pseudonymisation.generate_prenom(), pseudonymisation.generate_nom()) AS contact_technique,
    gouvernance_departement_code,
    old_uuid
    FROM min.membre
);


DROP TABLE IF EXISTS pseudonymisation.min_contact_membre_gouvernance;
CREATE TABLE pseudonymisation.min_contact_membre_gouvernance AS (
    SELECT contact AS email, pseudonymisation.generate_prenom() AS prenom, pseudonymisation.generate_nom() AS nom, 'Fonction' AS fonction
    FROM pseudonymisation.min_membre
    UNION
    SELECT contact_technique AS email, pseudonymisation.generate_prenom() AS prenom, pseudonymisation.generate_nom() AS nom, 'Fonction' AS fonction
    FROM pseudonymisation.min_membre
);
```

Certaines fois, des doublons d'adresses email sont générés, ce qui pose problème avec sso_email, d'où l'`UPDATE pseudonymisation.min_utilisateur`.

Pour les afficher :

```sql
SELECT sso_email, COUNT(*)
FROM pseudonymisation.min_utilisateur
GROUP BY sso_email
HAVING COUNT(*) > 1;
```


## Export des données

Une fois les données générer, il est possible de les exporter en faisant un dump SQL.

Les tables pseudonymisées seront dans le schéma `pseudonymisation` et nommées {schéma d'origine}_{nom de la table}.
A l'issu de la sauvegarde, il faudra modifier le dump SQL pour renommer les schémas/tables en conformité avec le modèle de données.

### Réalisation des dumps SQL

```sh
# Données administratives et de références
/usr/lib/postgresql/16/bin/pg_dump -d dataspace_xxx --data-only --disable-triggers -n admin -n reference -f dataspace-02-data-admin-ref.sql

# Données du schéma main
/usr/lib/postgresql/16/bin/pg_dump -d dataspace_xxx --data-only --disable-triggers -n main -T main.structure -T main.personne -t pseudonymisation.main_personne -t pseudonymisation.main_structure -f dataspace-03-data-main.sql

# Données du schéma min
/usr/lib/postgresql/16/bin/pg_dump -d dataspace_xxx --data-only --disable-triggers -n min -T min.utilisateur -T min.membre -T min.contact_membre_gouvernance -t pseudonymisation.min_utilisateur -t pseudonymisation.min_membre -t pseudonymisation.min_contact_membre_gouvernance -f dataspace-04-data-min.sql
```


### Renommage des tables

```sh
sed -i -e 's/pseudonymisation.main_personne/main.personne/g' -e 's/pseudonymisation.main_structure/main.structure/g' -e 's/pseudonymisation.min_contact_membre_gouvernance/min.contact_membre_gouvernance/g' -e 's/pseudonymisation.min_membre/min.membre/g' -e 's/pseudonymisation.min_utilisateur/min.utilisateur/g' dataspace-*-data-*.sql

# Pour supprimer la mention aux anciens noms des tables
sed -i -e '/-- Data/d' -e '/^--$/d' dataspace-*-data-*.sql

# Supprimer la directive transaction_timeout apparue en v17.
sed -i -e '/transaction_timeout/d' *.sql
```


### La structure

```sh
/usr/lib/postgresql/16/bin/pg_dump -d dataspace_xxx --section=pre-data -N min -N api -N auth -N cache -N dataviz -N import -N public -N pseudonymisation -f dataspace-01-structure-pre-data-hors_min.sql
/usr/lib/postgresql/16/bin/pg_dump -d dataspace_xxx --section=post-data -N min -N api -N auth -N cache -N dataviz -N import -N public -N pseudonymisation -f dataspace-05-structure-post-data-hors_min.sql

# Suppression de la création de l'extension pgcrypto, car schéma auth non présent
sed -i -e '/pgcrypto/d' -e '/^--$/d' dataspace-*-structure*.sql
```

## L'archivage

```sh
tar -czvf F008.20250725.tar.gz *.sql
```
