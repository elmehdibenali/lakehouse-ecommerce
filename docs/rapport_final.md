# Rapport final : Lakehouse E-commerce (v1.0)

## 1. Objectif

Construire un pipeline Big Data en PySpark, en architecture Médaillon, sur le jeu Olist (9 CSV, environ 100 000 commandes, 2016 à 2018), puis produire un modèle analytique fiable et mesurer ses performances. Le projet vise un résultat vérifiable : chaque chiffre publié est rapproché d'un chiffre attendu, et le chiffre d'affaires est réconcilié entre toutes les couches.

Environnement : Docker, JupyterLab, PySpark 3.5.0 en mode local (8 cœurs). Les documents de chaque étape sont dans `docs/`.

## 2. Architecture et choix

- **Bronze** : copie fidèle des sources. Un audit préalable a fixé les clés, les doublons et les valeurs manquantes (voir `audit_bronze.md`).
- **Silver** : typage, règles de qualité, et mise en quarantaine des cas incohérents plutôt que leur suppression silencieuse (voir `silver.md`). Les commandes sans produit sont signalées (`has_items = false`) et non supprimées.
- **Gold** : modèle dimensionnel de Kimball. Le grain est fixé avant la modélisation. Le modèle est une constellation à deux faits de grains différents (voir `gold.md`).

Principes appliqués dans tout le projet :

- agréger avant de joindre pour éviter la multiplication de lignes ;
- distinguer le constat (mesuré) de l'explication (hypothèse) ;
- vérifier la justesse d'une requête avant de l'optimiser.

## 3. Modèle Gold

| Table | Grain | Lignes × colonnes |
|---|---|---|
| `fact_order_items` | une ligne de commande | 112 626 × 13 |
| `fact_orders` | une commande | 99 410 × 34 |
| `dim_date` | un jour | 852 × 10 |
| `dim_product` | un produit | 32 951 × 12 |
| `dim_seller` | un vendeur | 3 095 × 7 |
| `dim_customer` | un client unique | 96 067 × 7 |

À cela s'ajoutent 17 tables d'indicateurs : `kpi_m1_pareto`, `kpi_m1_mensuel`, `kpi_m2_etat`, `kpi_m2_region`, `kpi_m3_statut`, `kpi_m3_tranche`, `kpi_m4_rfm`, `kpi_m4_segment`, `kpi_m4_reachat_seuil`, `kpi_m4_reachat_cohorte`, `kpi_m5_statut`, `kpi_m5_mensuel`, `kpi_m5_anomalies`, `kpi_m6_type`, `kpi_m6_combo`, `kpi_m6_echeances`, `kpi_m6_ecart_paiement`.

**Partitionnement.** Un test sur les tables Gold (environ 10 Mo) n'a montré aucun gain pratique : un fichier plat de 10 070 Ko contre trois fichiers de 9 684 Ko, filtre sur 2018 en 0,090 s contre 0,076 s, lecture complète en 0,074 s contre 0,147 s (l'élagage de partitions fonctionne). Décision : Gold n'est pas partitionné. À revoir à l'étape de montée en charge.

## 4. Réconciliation du chiffre d'affaires

| Étape | CA (R$) |
|---|---|
| Bronze | 13 591 643,70 |
| moins la quarantaine | 3 098,61 |
| Silver | 13 588 545,09 |
| moins les commandes annulées ou indisponibles | 97 242,96 |
| **Ventes (Gold)** | **13 491 302,13** |

Le CA des ventes se décompose aussi en 13 218 399,50 (commandes livrées) et 272 902,63 (commandes dans un statut non final). La chaîne se referme exactement, et la même valeur est retrouvée par les requêtes de l'étude d'optimisation.

La date de référence des calculs de récence est le lendemain de la dernière vente (2018-09-04), et non la dernière date toutes commandes confondues : un premier calcul avec la mauvaise référence avait faussé la récence minimale et les cohortes de rachat récentes, puis a été corrigé.

## 5. Résultats analytiques

Les valeurs sont des **constats**. Les causes ne sont pas établies, sauf mention contraire.

**M1, ventes par catégorie.** 18 catégories sur 74 réalisent 80 % du CA (Pareto).

**M2, géographie.** Le taux de commandes en retard est de 12,76 % dans le Nordeste, contre environ 6 % dans les autres régions.

**M3, livraison et satisfaction.**
- Note moyenne de 2,27 pour les commandes en retard contre 4,29 pour les autres.
- 74,46 % des avis de commandes en retard sont antérieurs à la date de livraison enregistrée : la relation entre retard et note ne peut donc pas être lue comme un effet causal direct du retard.
- 1 258 commandes à plusieurs vendeurs ont une note moyenne de 2,87, même livrées à l'heure.

**M4, clients.**
- Segmentation RFM sur 94 961 clients, avec des seuils de scores fixés par quantiles (reproductibles) et des sessions d'achat définies par un écart de 24 h.
- Taux de rachat de 3,04 % en brut, 2,15 % en excluant les commandes passées dans le même jour, et 1,28 % à 90 jours sur une cohorte à horizon fixe de 77 544 clients. L'horizon fixe évite le biais de censure à droite des clients récents.
- 791 clients récurrents recommandent en moins d'une heure.

**M5, statuts.** 1 713 commandes sont bloquées depuis plus de 60 jours dans un statut non final.

**M6, paiements.** 303 commandes ont un écart entre le paiement et la valeur de la commande. Cet écart est compatible avec des intérêts de paiement en plusieurs fois, mais cela n'est pas établi.

## 6. Optimisation Spark

Étude détaillée dans `Optimisation.md`. Mesures sur environ 10 Mo, 15 exécutions entrelacées par variante, règle de décision sur les intervalles interquartiles.

| Sujet | Constat |
|---|---|
| Plans d'exécution | Élagage de colonnes et filtre poussé dans Parquet ; dimensions en broadcast ; agrégation en deux temps. |
| Broadcast contre sort-merge | Le sort-merge forcé ajoute des shuffles (5 contre 1) et est environ 28 % plus lent sur la requête à deux jointures ; non distinguable sur la requête à une jointure. |
| Partitions de shuffle et AQE | Sans AQE avec 200 partitions, environ 3 fois plus lent (203 tâches contre 10). Avec l'AQE, partir de 200 ou de 2000 partitions revient au même. |
| Cache | Le cache de 14 colonnes est plus lent que l'absence de cache ; le cache des 3 colonnes utiles est environ 34 % plus rapide et occupe environ 7,6 fois moins de mémoire. |
| RDD | `reduceByKey` écrit environ 160 fois moins de shuffle que `groupByKey` ; l'API DataFrame est environ 2,1 fois plus rapide que les deux. |

## 7. Qualité et méthode

- Chaque étape est précédée de valeurs attendues issues de l'audit ; les écarts sont signalés, jamais comblés par une valeur devinée.
- Les erreurs rencontrées en cours de route ont été corrigées et documentées. Par exemple : une attente erronée de 10 lignes pour une table qui en compte 9 (la tranche de plus de 14 jours n'a pas d'avis postérieur à la livraison), un test de normalisation d'accents sans effet (aucun nom de ville non ASCII dans les données), et des compteurs de plan doublés par la lecture du plan initial et du plan final.
- Les mesures de performance ne sont comparées qu'au sein d'une même cellule : la même configuration a donné des médianes différentes d'une cellule à l'autre (par exemple 0,577 s puis 0,394 s).

## 8. Limites

- Volume faible (environ 10 Mo) et une seule machine : les conclusions d'optimisation ne se transposent pas telles quelles à de gros volumes.
- Les données couvrent 2016 à 2018 ; les indicateurs de rachat et de livraison sont descriptifs et ne permettent pas de conclure à des causes.
- Plusieurs mécanismes d'optimisation restent à l'état d'hypothèses (voir `Optimisation.md`).
- `skewJoin` n'a pas été testé.
- Les captures de la Spark UI sont à joindre à l'étude d'optimisation.

## 9. Compétences démontrées

Audit et qualité de données, modélisation dimensionnelle (grain, constellation, clés), PySpark (jointures, fenêtres, agrégations, plans d'exécution, AQE, cache, RDD), statistiques appliquées (intervalles de Wilson, horizon fixe, biais de censure et de sélection), méthode de mesure reproductible, documentation technique.

## 10. Suite

Refactoring en modules Python avec tests, Docker et Makefile, contrôles de qualité automatisés, Delta Lake, orchestration Airflow, intégration continue, test de montée en charge avec revue du partitionnement, tableau de bord. Ces étapes ne font pas partie de la version 1.0.