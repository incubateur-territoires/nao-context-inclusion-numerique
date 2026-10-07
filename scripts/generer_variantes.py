#!/usr/bin/env python3
"""Génère tests/variantes/ : pour chaque test tdb_* (hors lourds), trois reformulations
de la question avec le même SQL de référence.

  courte     : formulation orale et brève, comme au support.
  mots       : même demande avec d'autres termes métier.
  incomplete : sans les précisions de définition (le format de sortie est conservé
               pour que la comparaison porte sur la définition, pas sur les libellés).

Les variantes sont rédigées à la main ci-dessous, pas par le modèle évalué.
Relancer après modification ; le dossier généré est commité.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tests" / "variantes"

V: dict[str, dict[str, str]] = {
    "tdb_a_lieux_a_actualiser": {
        "courte": "Combien de lieux sont à actualiser sur le tableau de bord ?",
        "mots": "Nombre de lieux d'inclusion numérique actifs dont la fiche n'a pas été modifiée depuis plus de 18 mois (ou jamais), en France entière. Un mois vaut 30,44 jours ; 1 % de tolérance.",
        "incomplete": "Au niveau national, combien de lieux d'inclusion numérique sont « à actualiser » au sens du tableau de bord MIN ? Tolérance 1 %.",
    },
    "tdb_a_lieux_a_verifier": {
        "courte": "Combien de lieux à vérifier ?",
        "mots": "Nombre de lieux d'inclusion numérique actifs dont la fiche a entre 12 et 18 mois d'ancienneté de mise à jour (365 à 548 jours), France entière, tolérance 1 %.",
        "incomplete": "Au niveau national, combien de lieux d'inclusion numérique sont « à vérifier » au sens du tableau de bord MIN ? Tolérance 1 %.",
    },
    "tdb_b_accompagnements_6_mois_total": {
        "courte": "Total des accompagnements Coop sur les 6 derniers mois pleins ?",
        "mots": "Sur les six mois civils complets qui précèdent le mois courant, combien d'accompagnements au total ont été enregistrés dans la Coop, toutes structures, en pondérant chaque activité par son nombre d'accompagnements ? Activités supprimées exclues.",
        "incomplete": "Quel est le total des accompagnements déclarés dans la Coop sur les 6 derniers mois pleins, toutes structures confondues ?",
    },
    "tdb_b_lieux_avec_personne_affectee": {
        "courte": "Combien de lieux ont au moins une personne affectée active ?",
        "mots": "Nombre de lieux d'inclusion distincts avec au moins un rattachement de personne en cours (affectation active), tous lieux compris même archivés, sans condition sur la personne.",
        "incomplete": "Combien de lieux d'inclusion numérique distincts ont au moins une affectation de personne encore active ? Compter tous les lieux, y compris supprimés.",
    },
    "tdb_c_accompagnements_realises_total": {
        "courte": "Combien d'accompagnements réalisés au total, Coop et Aidants Connect ?",
        "mots": "Indicateur « accompagnements réalisés » du bloc État des lieux, national : accompagnements des aidants numériques (Aidants Connect) additionnés aux accompagnements de toutes les activités Coop non supprimées, sans borne de date. Chiffre exact.",
        "incomplete": "Au niveau national, quel est le nombre total d'accompagnements réalisés, tous dispositifs confondus, selon le bloc « État des lieux » du tableau de bord MIN ?",
    },
    "tdb_c_ifn_top10_departements": {
        "courte": "Top 10 des départements les plus fragiles numériquement ? Tableau département / score à 2 décimales.",
        "mots": "Classement des dix départements au score de fragilité numérique (IFN) le plus fort, du plus fragile au moins fragile ; tableau nom du département / score arrondi à deux décimales.",
        "incomplete": "Quels sont les 10 départements dont l'indice de fragilité numérique est le plus élevé ? Tableau nom du département / score arrondi à 2 décimales, du plus fragile au moins fragile.",
    },
    "tdb_c_lieux_inclusion_avec_adresse": {
        "courte": "Combien de lieux d'inclusion ont une adresse ?",
        "mots": "Nombre de lieux d'inclusion numérique géolocalisables (rattachés à une adresse), en comptant aussi les lieux archivés, France entière.",
        "incomplete": "Au niveau national, combien de lieux d'inclusion numérique disposent d'une adresse rattachée ?",
    },
    "tdb_c_mediateurs_et_aidants_en_poste": {
        "courte": "Combien de médiateurs et aidants numériques en poste ?",
        "mots": "Nombre de personnes actuellement en poste comme médiateur numérique ou comme aidant numérique, chaque personne comptée une seule fois, France entière.",
        "incomplete": "Au niveau national, combien de personnes sont actuellement médiateur numérique ou aidant numérique en poste ? (indicateur « Médiateurs et aidants numériques » du tableau de bord MIN)",
    },
    "tdb_d_detail_mediateurs": {
        "courte": "Parmi les médiateurs en poste : combien de coordinateurs, de conseillers numériques et d'Aidants Connect ? Tableau à trois lignes.",
        "mots": "Détail des médiateurs numériques actuellement en activité : tableau « Coordinateurs » / « Conseillers numériques » / « Aidants Connect » avec les effectifs, chaque ligne restreinte aux médiateurs en poste.",
        "incomplete": "Parmi les médiateurs numériques actuellement en poste, donne un tableau avec trois lignes « Coordinateurs », « Conseillers numériques », « Aidants Connect » et le nombre pour chacun.",
    },
    "tdb_d_mediateurs_numeriques": {
        "courte": "Combien de médiateurs numériques en poste ?",
        "mots": "Effectif national des médiateurs numériques actuellement en activité, tel qu'affiché dans le bloc médiateurs du tableau de bord.",
        "incomplete": "Au niveau national, combien de médiateurs numériques sont actuellement en poste ?",
    },
    "tdb_e_actions": {
        "courte": "Combien d'actions dans les feuilles de route ?",
        "mots": "Nombre total d'actions saisies dans l'ensemble des feuilles de route de MIN.",
        "incomplete": "Combien d'actions sont enregistrées dans les feuilles de route ?",
    },
    "tdb_e_feuilles_de_route": {
        "courte": "Combien de feuilles de route ?",
        "mots": "Nombre de feuilles de route présentes dans MIN, toutes gouvernances départementales confondues.",
        "incomplete": "Combien de feuilles de route ont été déposées dans MIN ?",
    },
    "tdb_e_gouvernances": {
        "courte": "Il y a combien de gouvernances ?",
        "mots": "Nombre de gouvernances départementales de l'inclusion numérique dans MIN.",
        "incomplete": "Combien de gouvernances existent ?",
    },
    "tdb_e_gouvernances_coportees": {
        "courte": "Combien de gouvernances co-portées ?",
        "mots": "Nombre de gouvernances départementales ayant au moins deux coporteurs non supprimés (candidats ou confirmés).",
        "incomplete": "Combien de gouvernances départementales sont co-portées ?",
    },
    "tdb_e_membres_coporteurs": {
        "courte": "Combien de membres coporteurs ?",
        "mots": "Nombre de membres de gouvernance actifs (candidats ou confirmés, non supprimés) qui sont coporteurs, toutes gouvernances.",
        "incomplete": "Combien de membres de gouvernance sont coporteurs, toutes gouvernances confondues ?",
    },
    "tdb_e_membres_gouvernance": {
        "courte": "Combien de membres de gouvernance au total ?",
        "mots": "Nombre total d'organisations membres des gouvernances départementales dans MIN, non supprimées (candidates ou confirmées), une organisation siégeant dans plusieurs départements étant comptée à chaque fois.",
        "incomplete": "Combien de membres de gouvernance non supprimés y a-t-il au total dans MIN ?",
    },
    "tdb_f_conum_enveloppes_consommation": {
        "courte": "Consommation des enveloppes Conseiller Numérique ? Tableau enveloppe / montant.",
        "mots": "Pour les enveloppes dont le nom commence par « Conseiller Numérique », montant national consommé : enveloppe Plan France Relance = total brut des subventions V1 des postes, enveloppe Renouvellement = total brut des subventions V2. Tableau libellé de l'enveloppe / euros.",
        "incomplete": "Pour chacune des enveloppes de financement « Conseiller Numérique », quelle est la consommation nationale en euros ? Tableau libellé complet de l'enveloppe / montant exact en euros.",
    },
    "tdb_f_conum_verse_conventionne": {
        "courte": "Montants conventionné et versé pour les postes Conseiller numérique ? Tableau « conventionné » / « versé ».",
        "mots": "D'après la synthèse des postes Conseiller numérique, total national des subventions cumulées (conventionné) et des versements cumulés (versé) : tableau à deux lignes « conventionné » et « versé », montants en euros.",
        "incomplete": "Au niveau national, quel est le montant total conventionné et le montant total versé pour les postes Conseiller numérique ? Tableau à deux lignes : « conventionné » / montant, « versé » / montant, en euros.",
    },
    "tdb_f_fne_engages_montant": {
        "courte": "Montant des financements FNE engagés par l'État, en euros ?",
        "mots": "Somme en euros des subventions demandées dont la demande est au statut acceptée et qui dépendent d'une action de feuille de route : c'est le montant France Numérique Ensemble engagé par l'État. Montant exact.",
        "incomplete": "Quel est le montant total, en euros, des financements France Numérique Ensemble engagés par l'État ? Montant exact, pas en millions.",
    },
    "tdb_f_fne_engages_nombre": {
        "courte": "Combien de financements FNE engagés par l'État ?",
        "mots": "Nombre de demandes de subvention acceptées rattachées à une action de feuille de route (financements engagés par l'État au titre de France Numérique Ensemble).",
        "incomplete": "Combien de financements ont été engagés par l'État au titre de France Numérique Ensemble ?",
    },
    "tdb_f_fne_par_enveloppe": {
        "courte": "Financements FNE engagés par enveloppe ? Tableau enveloppe / montant en euros.",
        "mots": "Ventilation par enveloppe des subventions demandées acceptées (rattachées à une action de feuille de route), toutes enveloppes sauf celles « Conseiller Numérique », quel que soit leur nom. Tableau libellé complet / montant exact en euros.",
        "incomplete": "Donne la ventilation par enveloppe de financement du montant des financements France Numérique Ensemble engagés par l'État. Tableau libellé complet de l'enveloppe / montant exact en euros.",
    },
    "tdb_g_beneficiaires_conum_par_enveloppe": {
        "courte": "Combien de structures bénéficiaires par enveloppe Conseiller Numérique ? Tableau enveloppe / nombre.",
        "mots": "Pour chaque enveloppe « Conseiller Numérique », nombre de structures distinctes ayant au moins un poste avec une subvention strictement positive : V1 pour Plan France Relance, V2 pour Renouvellement. Tableau libellé complet / nombre de structures.",
        "incomplete": "Pour chacune des enveloppes « Conseiller Numérique », combien de structures distinctes en ont bénéficié au niveau national ? Tableau libellé complet de l'enveloppe / nombre de structures.",
    },
    "tdb_g_beneficiaires_fne_par_enveloppe": {
        "courte": "Combien de membres bénéficiaires par enveloppe FNE ? Tableau enveloppe / nombre.",
        "mots": "Par enveloppe France Numérique Ensemble, nombre de membres de gouvernance distincts désignés bénéficiaires d'une demande de subvention acceptée liée à une action de feuille de route. Tableau libellé complet / nombre.",
        "incomplete": "Pour chaque enveloppe de financement France Numérique Ensemble, combien de membres de gouvernance distincts en sont bénéficiaires ? Tableau libellé complet de l'enveloppe / nombre de bénéficiaires distincts.",
    },
    "tdb_h_structures_eligibles_label_conum": {
        "courte": "Combien de structures éligibles au label conseiller numérique ?",
        "mots": "Nombre de structures distinctes ayant eu au moins un poste Conseiller numérique, peu importe l'état du poste (occupé, vacant, rendu) : éligibilité au label au sens du tableau de bord.",
        "incomplete": "Combien de structures sont éligibles au label « conseiller numérique » au sens du tableau de bord MIN ?",
    },
    "tdb_i_collectivites_par_categorie": {
        "courte": "Répartition des collectivités impliquées dans les gouvernances par catégorie (page admin) ? Tableau catégorie / nombre : Conseils départementaux, Conseils régionaux, EPCI, Communes, Autres.",
        "mots": "Page d'administration des gouvernances : nombre de membres collectivités, tous statuts y compris supprimés, selon les types retenus par la page (communes, EPCI et intercommunalités, collectivités territoriales, conseils départementaux, régions, préfectures). Tableau avec les catégories Conseils départementaux / Conseils régionaux / EPCI / Communes / Autres.",
        "incomplete": "Sur la page d'administration des gouvernances de MIN, donne la ventilation des « collectivités impliquées dans la gouvernance » par catégorie : « Conseils départementaux », « Conseils régionaux », « EPCI », « Communes », « Autres ». Tableau catégorie / nombre de membres.",
    },
    "tdb_i_feuilles_de_route_avec_demandes": {
        "courte": "Combien de feuilles de route ont au moins une demande de subvention ?",
        "mots": "Nombre de feuilles de route dont une action au moins porte une demande de subvention, peu importe l'état de la demande.",
        "incomplete": "Combien de feuilles de route comportent au moins une demande de subvention ?",
    },
    "tdb_i_feuilles_de_route_par_perimetre": {
        "courte": "Feuilles de route par périmètre géographique ? Tableau départemental / infra-départemental / régional / Autre.",
        "mots": "Répartition des feuilles de route selon leur échelle territoriale : « départemental », « infra-départemental » (groupements de communes), « régional », « Autre » quand le périmètre est vide. Une ligne par libellé avec le compte.",
        "incomplete": "Donne la répartition des feuilles de route par périmètre géographique, tableau avec exactement ces libellés : « départemental », « infra-départemental », « régional », « Autre ».",
    },
    "tdb_i_gouvernances_sans_coporteur": {
        "courte": "Combien de gouvernances sans coporteur (page admin) ?",
        "mots": "Sur la page d'administration des gouvernances, nombre de gouvernances dont le seul coporteur est la préfecture (un unique membre coporteur), tous membres comptés quel que soit leur statut, supprimés inclus.",
        "incomplete": "Sur la page d'administration des gouvernances de MIN, combien de gouvernances sont « sans coporteur » ?",
    },
    "tdb_s_accompagnements_par_mois": {
        "courte": "Accompagnements par mois sur les 6 derniers mois pleins ? Tableau AAAA-MM / nombre.",
        "mots": "Page Statistiques, national : pour chacun des six mois civils complets précédant le mois en cours, nombre de participations de bénéficiaires à des activités Coop non supprimées (une ligne d'accompagnement par bénéficiaire). Tableau mois au format AAAA-MM / nombre.",
        "incomplete": "Sur la page Statistiques de MIN au niveau national, donne le nombre d'accompagnements par mois sur les 6 derniers mois pleins, tableau mois (AAAA-MM) / nombre.",
    },
    "tdb_s_accompagnements_total": {
        "courte": "Nombre total d'accompagnements sur la page Statistiques ?",
        "mots": "Page Statistiques, France entière : total des accompagnements depuis le début du dispositif (17/11/2020) jusqu'à aujourd'hui, activités Coop non supprimées, chaque activité pesant son nombre d'accompagnements. Tolérance 1 %.",
        "incomplete": "Sur la page Statistiques de MIN au niveau national, quel est le nombre total d'accompagnements ? Tolérance 1 %.",
    },
    "tdb_s_beneficiaires_suivis": {
        "courte": "Combien de bénéficiaires suivis sur la page Statistiques ?",
        "mots": "Page Statistiques, national : nombre de bénéficiaires identifiés (fiches non anonymes) distincts ayant au moins un accompagnement dans une activité Coop non supprimée entre le 17/11/2020 et aujourd'hui. Tolérance 1 %.",
        "incomplete": "Sur la page Statistiques de MIN au niveau national, combien de bénéficiaires suivis distincts y a-t-il ? Tolérance 1 %.",
    },
    "tdb_s_canaux": {
        "courte": "Répartition des accompagnements par canal (page Statistiques) ? Tableau avec « Lieu d'activité », « Autre lieu », « À domicile », « À distance ».",
        "mots": "Page Statistiques, national : accompagnements selon le type de lieu de l'activité, libellés « Lieu d'activité », « Autre lieu », « À domicile », « À distance », chaque canal totalisant le nombre d'accompagnements de ses activités, depuis le 17/11/2020, activités non supprimées. Tolérance 1 %.",
        "incomplete": "Sur la page Statistiques de MIN au niveau national, donne la répartition des accompagnements par canal, tableau avec exactement ces libellés : « Lieu d'activité », « Autre lieu », « À domicile », « À distance ». Tolérance 1 %.",
    },
    "tdb_s_durees": {
        "courte": "Répartition des accompagnements par durée (page Statistiques) ? Tableau « Moins de 30 min », « 30min à 1 h », « 1 h à 2 h », « 2 h et plus ».",
        "mots": "Page Statistiques, national : accompagnements par tranche de durée d'activité en minutes, bornes [0,30[ « Moins de 30 min », [30,60[ « 30min à 1 h », [60,120[ « 1 h à 2 h », 120 et plus « 2 h et plus » ; durée absente ignorée ; chaque tranche totalise le nombre d'accompagnements des activités ; depuis le 17/11/2020, non supprimées. Tolérance 1 %.",
        "incomplete": "Sur la page Statistiques de MIN au niveau national, donne la répartition des accompagnements par durée d'activité, tableau avec exactement ces libellés : « Moins de 30 min », « 30min à 1 h », « 1 h à 2 h », « 2 h et plus ». Tolérance 1 %.",
    },
    "tdb_s_thematiques_demarches": {
        "courte": "Répartition des accompagnements par thématique de démarche administrative (page Statistiques) ? Tableau identifiant de thématique / nombre, du plus fréquent au moins fréquent.",
        "mots": "Page Statistiques, national : pour chaque thématique de démarches administratives (identifiants enregistrés : papiers_elections_citoyennete, famille_scolarite, social_sante, travail_formation, logement, transports_mobilite, argent_impots, justice, etrangers_europe, loisirs_sports_culture, associations), somme des accompagnements des activités concernées, multi-thématiques comptées dans chacune, depuis le 17/11/2020, non supprimées. Tableau identifiant / nombre décroissant. Tolérance 1 %.",
        "incomplete": "Sur la page Statistiques de MIN au niveau national, donne la répartition des thématiques d'accompagnement aux démarches administratives. Tableau identifiant de thématique (tel qu'enregistré : papiers_elections_citoyennete, famille_scolarite, social_sante, travail_formation, logement, transports_mobilite, argent_impots, justice, etrangers_europe, loisirs_sports_culture, associations) / nombre, du plus fréquent au moins fréquent. Tolérance 1 %.",
    },
    "tdb_s_thematiques_mediation_top10": {
        "courte": "Top 10 des thématiques de médiation numérique (page Statistiques) ? Tableau identifiant de thématique / nombre.",
        "mots": "Page Statistiques, national : les dix thématiques de médiation numérique les plus fréquentes, chaque thématique totalisant les accompagnements des activités qui la portent (multi-thématiques comptées dans chacune), depuis le 17/11/2020, activités non supprimées. Tableau identifiant enregistré (diagnostic_numerique, prendre_en_main_du_materiel, maintenance_de_materiel, gere_ses_contenus_numeriques, navigation_sur_internet, email, bureautique, reseaux_sociaux, sante, banque_et_achats_en_ligne, entrepreneuriat, insertion_professionnelle, securite_numerique, parentalite, scolarite_et_numerique, creer_avec_le_numerique, culture_numerique, intelligence_artificielle, aide_aux_demarches_administratives) / nombre décroissant. Tolérance 1 %.",
        "incomplete": "Sur la page Statistiques de MIN au niveau national, quelles sont les 10 thématiques de médiation numérique les plus fréquentes ? Tableau identifiant de thématique tel qu'enregistré / nombre, du plus fréquent au moins fréquent. Tolérance 1 %.",
    },
}


def main() -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    n = 0
    for p in sorted((ROOT / "tests").glob("tdb_*.yml")):
        t = yaml.safe_load(p.read_text())
        if "lourd" in (t.get("tags") or []):
            continue
        variantes = V.get(p.stem)
        assert variantes, f"variantes manquantes pour {p.stem}"
        for kind, prompt in variantes.items():
            out = {
                "name": f"{p.stem}__{kind}",
                "prompt": prompt,
                "kind": t.get("kind", "scalar"),
                "rtol": t.get("rtol", 0.005),
                "tags": ["variante", kind] + [x for x in (t.get("tags") or []) if x not in ("tableau-de-bord",)],
                "sql": t["sql"],
            }
            lines = []
            for k, v in out.items():
                if k == "sql":
                    lines.append("sql: |\n" + "\n".join("  " + l for l in v.rstrip("\n").splitlines()))
                elif k == "prompt":
                    lines.append("prompt: " + yaml.safe_dump(v, allow_unicode=True, default_style='"', width=10000).strip())
                elif isinstance(v, list):
                    lines.append(f"{k}: [{', '.join(map(str, v))}]")
                else:
                    lines.append(f"{k}: {v}")
            (OUT / f"{out['name']}.yml").write_text("\n".join(lines) + "\n")
            n += 1
    print(f"{OUT.relative_to(ROOT)} : {n} variantes")


if __name__ == "__main__":
    main()
