# Champ `contact` (JSONB) des personnes

## Structure

Le champ `contact` de `main.personne` stocke les informations de contact
**par source**, chaque source ayant sa propre cle top-level :

```json
{
  "coop": {
    "email": "contact@exemple.fr",
    "telephone": "+33100000000"
  },
  "idposte": {
    "mail_pro": "pro@exemple.fr",
    "mail_perso": "prenom.nom@exemple.fr"
  }
}
```

### Sources

| Source | Cle | Champs | Origine |
|--------|-----|--------|---------|
| **Coop** | `coop` | `email`, `telephone` | API `/api/v1/utilisateurs` |
| **idPoste** | `idposte` | `mail_pro`, `mail_perso` | CSV conseillers numeriques |

### Construction

- `etl/extract/connectors/http_airflow.py` : `build_contact()` pour la coop
- `etl/transform/ingest/postes_conum.py` : `create_emails_column_personne()` pour idPoste

## Fusion dans les DAGs

Chaque source ecrit uniquement dans sa propre cle top-level. Le merge est un
simple `||` sur JSONB, ce qui preserve les cles des autres sources.

### `coop-dag.py` (import utilisateurs coop)

```sql
contact = COALESCE(p.contact, '{}'::jsonb) || COALESCE(s.contact, '{}'::jsonb)
```

L'incoming `{"coop": {...}}` s'ajoute/ecrase la cle `coop` sans toucher a `idposte`.

### `schema-idPoste.py` (import postes conseillers numeriques)

```sql
contact = COALESCE(main.personne.contact, '{}'::jsonb) || COALESCE(EXCLUDED.contact, '{}'::jsonb)
```

L'incoming `{"idposte": {...}}` s'ajoute/ecrase la cle `idposte` sans toucher a `coop`.

### `personne-similarities-dag.py` (fusion de doublons)

```sql
contact = COALESCE(p_loser.contact, '{}'::jsonb) || COALESCE(p_winner.contact, '{}'::jsonb)
```

Le winner l'emporte pour chaque source. Le loser est supprime.

## Lecture dans les vues

### Emails (dataviz.personne, dataviz.poste)

```sql
concat_ws(', ',
    contact -> 'coop' ->> 'email',
    contact -> 'idposte' ->> 'mail_pro',
    contact -> 'idposte' ->> 'mail_perso'
) AS emails
```

### Telephone (dataviz.personne)

```sql
contact -> 'coop' ->> 'telephone' AS "Téléphone"
```

### Recherche par email (api.get_mediateur — fonction supprimée en V157, extrait historique)

```sql
WHERE p.contact -> 'coop' ->> 'email' = email
   OR p.contact -> 'idposte' ->> 'mail_pro' = email
   OR p.contact -> 'idposte' ->> 'mail_perso' = email
```

## Migration V046

La migration `V046_20260224__contact_personne_par_source.sql` met a jour :
- `api.get_mediateur()` : recherche par email sur toutes les sources
- `dataviz.personne` : emails et telephone depuis les nouvelles cles
- `dataviz.poste` : emails personne (contact structure inchange)
- `api.carto` : email/telephone mediateur depuis `coop`

La migration des donnees se fait par re-importation des CSV sources
(coop-dag et schema-idPoste).
