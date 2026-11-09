# Couche Gold

Ce document décrit la couche Gold : le modèle en étoile, les indicateurs qui répondent aux questions M1 à M6, la réconciliation du chiffre d'affaires, le test de partitionnement, les validations passées et les points ouverts. Les chiffres viennent de `notebooks/03_gold.ipynb`. Les règles de nettoyage amont sont dans `docs/silver.md`.

Principe : Gold ne nettoie plus. Chaque table a un grain unique, chaque chiffre est réconcilié avec la source, et ce qui n'est pas établi est écrit comme tel (constat et explication sont séparés).

## 1. Inventaire

23 tables dans `data/gold/` (non versionné) : 2 tables de faits, 4 dimensions, 17 tables d'indicateurs.

| Table | Lignes | Colonnes | Grain (une ligne =) |
|---|---|---|---|
| fact_order_items | 112 626 | 13 | une ligne produit d'une commande |
| fact_orders | 99 410 | 34 | une commande |
| dim_date | 852 | 10 | un jour (2016-09-01 à 2018-12-31) |
| dim_product | 32 951 | 12 | un produit |
| dim_seller | 3 095 | 7 | un vendeur |
| dim_customer | 96 067 | 7 | une personne (`customer_unique_id`) ayant au moins une commande en Silver |

| Table d'indicateurs | Lignes | Question |
|---|---|---|
| kpi_m1_pareto | 74 | M1 : CA par catégorie, part cumulée |
| kpi_m1_mensuel | 1 245 | M1 : CA par mois et catégorie (fenêtre) |
| kpi_m2_etat | 27 | M2 : délais et retards par État |
| kpi_m2_region | 5 | M2 : délais et retards par région |
| kpi_m3_statut | 4 | M3 : note selon le statut de retard (2 périmètres d'avis) |
| kpi_m3_tranche | 9 | M3 : note selon la tranche de retard (2 périmètres d'avis) |
| kpi_m4_rfm | 94 961 | M4 : R, F, M, scores et segment par client |
| kpi_m4_segment | 6 | M4 : synthèse par segment |
| kpi_m4_reachat_seuil | 5 | M4 : taux de réachat selon le seuil de délai |
| kpi_m4_reachat_cohorte | 21 | M4 : réachat à 90 jours par mois de première commande |
| kpi_m5_statut | 7 | M5 : répartition des commandes par statut |
| kpi_m5_mensuel | 20 | M5 : commandes non abouties par mois |
| kpi_m5_anomalies | 9 | M5 : anomalies de statut et de dates |
| kpi_m6_type | 4 | M6 : répartition par type de paiement |
| kpi_m6_combo | 6 | M6 : panier selon la combinaison de moyens de paiement |
| kpi_m6_echeances | 5 | M6 : panier selon les échéances (carte seule) |
| kpi_m6_ecart_paiement | 4 | M6 : commandes dont le paiement diffère de produits plus frais |

## 2. Modèle en étoile

Deux tables de faits à deux grains différents (constellation de faits). Les mesures de commande (paiement, avis, délais) ne sont pas copiées sur les lignes produit : sommées après jointure, elles seraient répétées autant de fois qu'il y a de lignes (même mécanisme que les 4,5 % de CA gonflé de l'étape 0.4).

- **fact_order_items** : clés `order_id`, `order_item_id`, `product_id`, `seller_id`, `customer_unique_id`, `order_date_key` ; mesures `price`, `freight_value` ; attributs hérités de la commande `order_status`, `is_sale`, `in_analysis_window`, `customer_state` (descriptifs, non additifs).
- **fact_orders** : issue de `orders_enriched`, sans `customer_id`, `customer_city`, `customer_has_geo`, les deux dates d'avis et les 3 métadonnées d'ingestion ; ajout de `order_date_key`.
- **Clés naturelles** plutôt que clés de substitution : données figées, pas d'historisation (SCD), et un `row_number` global ramènerait tout sur une seule partition. À revoir pour l'ingestion incrémentale (étape 10).
- **dim_geo abandonnée** : `dim_customer` et `dim_seller` portent déjà `lat`, `lng` et `has_geo`. `geolocation` reste en Silver pour une éventuelle carte.
- **dim_customer** : adresse de la commande la plus récente (second critère `customer_id`). 39 personnes ont plusieurs États et 122 plusieurs villes ; `fact_orders` garde l'État de la commande elle-même. Les 29 personnes dont toutes les commandes sont en quarantaine en sont exclues (`inner join`).
- **dim_product** : colonnes `lenght` renommées `length`, ajout de `product_volume_cm3`.
- Les dimensions et faits sont écrits en un seul fichier (`coalesce(1)`).

## 3. Indicateurs par question

### M1. Ventes par catégorie

Périmètre du Pareto : toutes les ventes (`is_sale`), CA de référence 13 491 302,13. Évolution mensuelle : fenêtre 2017-01 à 2018-08 (CA 13 446 431,07 ; hors fenêtre 44 871,06, soit 0,33 %).

- 74 catégories avec ventes. **18 catégories (24 %) font 80 % du CA** : ce n'est pas un 80/20 strict.
- Top 5 : health_beauty 9,3 %, watches_gifts 8,9 %, bed_bath_table 7,7 %, sports_leisure 7,3 %, computers_accessories 6,7 % (39,8 % à eux cinq).
- `unknown` (610 produits sans catégorie) : 178 522,56, soit 1,32 % du CA, rang 21.
- Le top 10 est identique et au même rang sur toute la période et sur la fenêtre ; 4 catégories sur 74 changent de rang, toutes au-delà du rang 10.
- Les parts mensuelles sont volatiles, surtout en début de fenêtre (volumes faibles) ; ce sont des parts du CA du mois, pas des CA.

### M2. Délai de livraison

Population : commandes `delivered` de la fenêtre, 96 188 (267 écartées par la fenêtre, 0,28 %). `is_late` équivaut à `delay_days > 0` (contrôlé).

- National : délai moyen 12,54 j, médian 10,21, p90 23,06, p99 46,0, maximum 209,63 ; délai promis moyen 23,65 j ; **taux de retard 6,79 %** [6,63 ; 6,95].
- La moyenne dépasse la médiane : distribution à queue longue.

| Région | Commandes | Délai moyen (j) | Délai promis moyen (j) | Taux de retard | Intervalle à 95 % |
|---|---|---|---|---|---|
| Sudeste | 66 009 | 10,73 | 21,53 | 6,13 % | [5,95 ; 6,31] |
| Sul | 13 765 | 14,02 | 26,32 | 5,92 % | [5,54 ; 6,33] |
| Centro-Oeste | 5 610 | 15,01 | 26,57 | 6,54 % | [5,92 ; 7,22] |
| Nordeste | 9 013 | 19,99 | 30,54 | **12,76 %** | [12,09 ; 13,46] |
| Norte | 1 791 | 22,59 | 37,44 | 8,60 % | [7,39 ; 9,99] |

- Par État : SP concentre 40 393 commandes (42 %) avec 8,74 j et 4,5 % de retard ; RJ, 12 308 commandes, a 12,15 % de retard.
- Les États aux délais les plus longs (RR, AP, AM, AC) n'ont pas les taux de retard les plus élevés, car leur date promise est plus lointaine. Cela n'explique pas tout : RJ a une marge moyenne un peu supérieure à SP pour un retard bien plus fréquent, ce que la dispersion des délais (p90 de 29,08 contre 15,69 j) peut expliquer ; la cause n'est pas établie.
- Les taux des petits États (RR 40 commandes, AP 67, AC 80) sont fragiles : intervalle de Wilson affiché. Deux intervalles qui se chevauchent ne prouvent pas l'égalité de deux taux.
- Les régions sont un dictionnaire manuel (découpage IBGE), pas une donnée du dataset.

### M3. Retards et satisfaction

Population : commandes livrées de la fenêtre avec avis, 95 545 (643 sans avis). Corrélation de Pearson entre `delay_days` et la note : −0,27 (linéaire, mêle avance et retard).

| Tranche de retard | Avis | Note moyenne (± marge 95 %) | Notes 1 et 2 |
|---|---|---|---|
| à l'heure ou en avance | 89 168 | 4,291 (± 0,008) | 9,3 % |
| 1 à 3 j | 1 851 | 3,291 (± 0,072) | 32,1 % |
| 4 à 7 j | 1 747 | 2,101 (± 0,071) | 67,7 % |
| 8 à 14 j | 1 446 | 1,671 (± 0,062) | 80,2 % |
| plus de 14 j | 1 333 | 1,725 (± 0,067) | 78,3 % |

- À l'heure 4,291 contre en retard 2,270 (écart −2,02).
- **74,46 % des avis des commandes en retard sont créés avant la date de livraison enregistrée**, contre 0,25 % pour les commandes à l'heure. L'écart global mêle donc des notes écrites avant la réception.
- Sur les avis postérieurs à la livraison (90 576) : 4,292 à l'heure contre 3,526 en retard (1 629 avis, ± 0,073), soit −0,77. Retards de 1 à 3 j : 3,532 ; 4 à 7 j : 3,479 (163 avis, ± 0,243) ; 8 à 14 j : 1 seul avis ; plus de 14 j : aucun. Ce périmètre ne dit rien des retards graves.
- Stratification : l'écart reste entre −1,93 et −2,08 dans chacune des 5 régions.
- **Corrélation, pas causalité.** Biais de sélection possible sur les avis postérieurs (ceux qui notent tôt sont peut-être les plus mécontents), non vérifié.

### M4. Fidélité et valeur client

Population : 94 961 clients ayant au moins une vente (`is_sale`), 98 176 commandes, montant = `items_total`. Dernière vente : 2018-09-03 ; référence de récence : 2018-09-04.

- 92 075 clients (97,0 %) n'ont qu'une commande. Réachat selon le seuil de délai depuis la première commande : tout réachat 3,04 % (2 886 clients), au moins 1 h 2,21 %, au moins 1 jour 2,15 %, au moins 7 jours 1,98 %, au moins 30 jours 1,57 %.
- 791 clients (27 % des récurrents) ont toutes leurs commandes supplémentaires dans l'heure qui suit la première ; 965 des 3 215 commandes de suite arrivent moins de 24 h après la précédente (commandes scindées ? non établi).
- Réachat à 90 jours (au moins 1 jour d'écart), cohorte de 77 544 clients dont la première commande précède d'au moins 90 jours la dernière vente : **1,28 %** (de 0,86 % à 1,82 % selon le mois, sans tendance nette). Un premier calcul avec la fin de dataset « tous statuts » donnait 1,24 % et biaisait les derniers mois ; corrigé.
- Sessions d'achat (commandes espacées de moins de 24 h fusionnées) : 92 925 clients à 1 session, 1 884 à 2, 152 à 3 ou plus. Hypothèse des 24 h peu sensible : seuil de 1 h et de 24 h diffèrent de 57 clients.
- Scores : R et M par seuils de valeurs issus des quintiles (récence [99, 183, 274, 389] jours ; montant [39,9 ; 69,9 ; 109,9 ; 179,9]), F sur 3 niveaux (1, 2, 3 sessions ou plus). Seuils par valeur plutôt que `ntile` : des clients au comportement identique reçoivent le même score. Contrepartie : groupes de score M inégaux (de 17 720 à 19 730 clients).

| Segment | Clients | Part des clients | Part du CA |
|---|---|---|---|
| occasionnels à forte valeur à réactiver | 21 443 | 22,6 % | 42,9 % |
| nouveaux à forte valeur | 14 835 | 15,6 % | 29,6 % |
| occasionnels inactifs | 34 486 | 36,3 % | 14,3 % |
| nouveaux | 22 161 | 23,3 % | 9,2 % |
| fidèles actifs | 1 083 | 1,1 % | 2,2 % |
| fidèles à réactiver | 953 | 1,0 % | 1,9 % |

- « Nouveaux » désigne un achat unique dans les ~183 derniers jours, pas forcément un premier achat récent. Les règles de segmentation sont des hypothèses de travail.
- La part du CA des segments à forte valeur est en partie mécanique (M ≥ 4 = les 40 % qui dépensent le plus). Le dataset ne permet pas d'estimer le gain d'une campagne de réactivation (pas de marge, pas de coût, pas d'expérience témoin).

### M5. Annulations et anomalies

Base : 99 410 commandes Silver. Les 31 commandes en quarantaine ne sont ni `canceled` ni `unavailable`.

- Répartition : delivered 96 455, shipped 1 106, canceled 625, unavailable 609, invoiced 312, processing 301, approved 2, created 0.
- **1 234 commandes non abouties (1,24 %)**, CA associé 97 242,96 (461 `canceled` et 6 `unavailable` avec produits).
- Taux mensuel (fenêtre) de 0,29 % (2018-04) à 3,51 % (2017-02), avec intervalles de Wilson ; en 2017 `unavailable` domine souvent, à partir de 2018-03 `canceled` domine (84 contre 7 en 2018-08). Cause non établie.
- **1 713 commandes (1,72 %) en statut non final depuis plus de 60 jours** : 1 098 `shipped`, 312 `invoiced`, 301 `processing`, 2 `approved`. Elles portent 272 902,63 de CA des ventes (2,02 %). CA des ventes 13 491 302,13 = CA `delivered` 13 218 399,50 + CA des statuts non finaux 272 902,63.
- La part de statuts non finaux par mois baisse de 4,64 % (2017-01) à environ 1 % en 2018 : pas de signe que les mois récents soient moins « fermés ».
- Anomalies : quarantaine 23 `delivered_missing_date` et 8 `no_items_inconsistent_status` ; 6 annulées mais livrées ; 1 359 transporteur avant approbation ; 23 livraison avant transporteur ; 0 commande sans produit hors `canceled`/`unavailable` en Silver.

### M6. Paiements

Population : commandes `is_sale` (102 542 paiements, 98 175 commandes avec paiement, valeur 15 734 694,45).

| Type | Part des paiements | Part de la valeur | Échéances moyennes |
|---|---|---|---|
| carte de crédit | 74,0 % | 78,5 % | 3,51 |
| boleto | 19,0 % | 18,0 % | 1,0 |
| voucher | 5,5 % | 2,2 % | 1,0 |
| carte de débit | 1,5 % | 1,35 % | 1,0 |

- Panier moyen (`items_total`) : carte seule 143,37 (médiane 89,90), boleto 121,71 (74,99), carte + voucher 126,42, voucher seul 86,05, débit 119,49. Dispersion non calculée.
- Carte seule (73 395 commandes) : panier moyen 82,42 à 1 échéance, 113,78 à 2-3, 157,20 à 4-6, 300,63 à 7-10, 321,75 à 11 et plus (324 commandes). **Association, pas effet** : les clients à panier élevé choisissent peut-être plus souvent de payer en plusieurs fois.
- **303 commandes dont le paiement diffère de produits plus frais de plus d'un centime** (sur 98 642 comparables) : 275 sur carte seule (249 écarts positifs), 14 sur boleto (bruit d'arrondi), 7 sur carte + voucher (tous positifs), 7 sur débit (tous négatifs). Le taux d'écart des commandes par carte croît avec les échéances (0,04 % à 1 échéance, 0,72 % à 7-10, 7,4 % à 11 et plus, 24 commandes), compatible avec des intérêts sans l'établir ; 99,3 % des commandes à 7-10 échéances n'ont aucun écart. Cause non établie.

## 4. Réconciliation du chiffre d'affaires

| Étape / table | Montant |
|---|---|
| CA source (Bronze) | 13 591 643,70 |
| moins : lignes des commandes en quarantaine | 3 098,61 |
| **CA Silver = fact_order_items** | **13 588 545,09** |
| moins : commandes `canceled` et `unavailable` | 97 242,96 |
| **CA des ventes (`is_sale`)** | **13 491 302,13** |

Le même CA des ventes est retrouvé dans `fact_orders`, `kpi_m1_pareto`, `kpi_m4_rfm` et `kpi_m4_segment` ; `kpi_m1_mensuel` donne 13 446 431,07 (fenêtre) ; `kpi_m5_statut` donne 13 588 545,09 (tous statuts). Écart maximal : 0,00. Identité Bronze − quarantaine − Silver = 0.

## 5. Partitionnement : test et décision

`fact_order_items` a été écrite en deux versions dans un dossier temporaire (supprimé ensuite) : un fichier, et partitionnée par année de commande.

| Mesure | Fichier unique | Partitionné par année |
|---|---|---|
| Fichiers, taille | 1 fichier, 10 070 Ko | 3 fichiers, 9 684 Ko |
| Lignes par année | 2016 : 370 ; 2017 : 50 846 ; 2018 : 61 410 | idem |
| Temps médian, filtre 2018 | 0,090 s | 0,076 s |
| Temps médian, lecture totale | 0,074 s | 0,147 s |
| CA 2018 / CA total | 7 385 097,92 / 13 588 545,09 | identique |

Le plan de la version partitionnée montre `PartitionFilters: order_year = 2018` : l'élagage de partitions fonctionne. Mais les écarts de temps sont de quelques dizaines de millisecondes sur 10 Mo, en mode local, avec 5 mesures : de l'ordre du bruit. La partition 2016 ne contient que 370 lignes (petit fichier).

**Décision : tables Gold non partitionnées à ce volume.** Le partitionnement sera réévalué à l'étape 13 (benchmark et scalabilité) sur un volume multiplié.

## 6. Validations passées

| Contrôle | Résultat |
|---|---|
| Clés : couples (`order_id`, `order_item_id`), `product_id`, `seller_id`, `customer_unique_id` | uniques |
| Orphelins fait vers dimensions (produit, vendeur, client, date) | 0 partout |
| Orphelins `fact_orders` vers `dim_customer` et `dim_date` | 0 |
| Cohérence des deux faits (somme des prix et nombre de lignes par commande) | 0 commande en désaccord |
| Réconciliation du CA (11 contrôles) | tous OK, tolérance 1 centime |
| Tables relues depuis le disque | 23 dossiers, comptages conformes |

## 7. Décisions et hypothèses

- **`is_sale`** n'exclut que `canceled` et `unavailable` : le CA des ventes inclut 2,02 % de commandes en statut non final. Le CA livré (13 218 399,50) est donné comme borne basse.
- **Population de M2 et M3** : `delivered` de la fenêtre ; M3 sur les commandes avec avis, deux périmètres.
- **Tranches de retard** (à l'heure, 1-3, 4-7, 8-14, plus de 14 j) fixées avant de voir les résultats.
- **Intervalles de Wilson à 95 %** pour les taux (retard, annulation) ; marge normale sur la moyenne des notes.
- **Session d'achat de 24 h**, hypothèse peu sensible (1 h donne presque le même résultat).
- **Fin de référence** : dernière vente (2018-09-03) pour la récence et la cohorte de réachat ; fin de dataset tous statuts (2018-10-17) pour l'ancienneté des statuts, comme R7.
- **Régions** : dictionnaire manuel IBGE.
- **Gold non partitionné** (voir section 5).

## 8. Points ouverts et limites

- **1 258 commandes multi-vendeurs** ont une note moyenne de 2,87 même quand elles arrivent à l'heure (4,31 pour les commandes à un seul vendeur) ; seulement 12 sont en retard. Cause non établie.
- **Avis antérieurs à la livraison** : 74,46 % pour les commandes en retard. Peut refléter l'attente d'une commande en retard ou une date de livraison enregistrée après l'arrivée réelle ; les données ne tranchent pas.
- **Statuts bloqués** : 1 713 commandes en statut non final depuis plus de 60 jours, 2,02 % du CA des ventes en statut non final. L'état final réel n'est pas dans le dataset.
- **Composition des non-abouties** : `unavailable` quasi disparu à partir de 2018-03. Cause non établie.
- **303 écarts de paiement** : cause non établie (voir M6).
- **Un client à 16 commandes** conservé ; nature inconnue.
- **Alias de villes** (« embu » et « embu das artes ») : les 122 personnes à plusieurs villes et les 39 codes postaux à plusieurs villes ne s'expliquent ni par la casse, les espaces ou les accents (0 ville avec caractère non ASCII). Sans impact sur M2 (par État).
- **Dernière vente le 2018-09-03** alors que le dataset va jusqu'au 2018-10-17 (19 commandes hors vente après la dernière vente).
- **371 lignes produit** (0,33 %) hors fenêtre d'analyse.
- **Journal des règles Silver** : pas de ligne pour R13, et le sens de « avant » et « après » varie selon la règle (voir `docs/silver.md`).
- **Prix de catalogue** : les seuils de montant du RFM sont des prix usuels (39,9 ; 69,9...), d'où des groupes de score M inégaux.

## 9. Entrées pour l'étape 4

Les tables de faits et dimensions servent de base aux mesures d'optimisation : jointure `fact_order_items` avec `dim_product` (broadcast), agrégation par catégorie (Pareto), fonctions de fenêtre du RFM et des sessions d'achat (partition par client), nombre de partitions de shuffle.