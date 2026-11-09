# Optimisation Spark (étape 4)

Ce document décrit les mesures faites sur la couche Gold du projet lakehouse-ecommerce (dataset Olist). Chaque résultat est classé en **constat** (mesuré) ou **hypothèse** (non démontrée). Les temps ne sont comparables qu'à l'intérieur d'une même cellule de mesure (voir la section Limites).

## 1. Périmètre et environnement

| Élément | Valeur |
|---|---|
| Spark | 3.5.0, mode local, 8 cœurs (`defaultParallelism` = 8), dans Docker |
| Données | tables Gold en Parquet, environ 10 Mo au total (`fact_order_items` 112 626 lignes, `fact_orders` 99 410 lignes) |
| `spark.sql.shuffle.partitions` | 200 (défaut) |
| AQE (`spark.sql.adaptive.enabled`) | `true`, regroupement des partitions de shuffle actif |
| `spark.sql.autoBroadcastJoinThreshold` | 10 485 760 octets (10 Mo) |
| `advisoryPartitionSizeInBytes` | 64 Mo |
| `coalescePartitions.parallelismFirst` / `minPartitionSize` | `true` / 1 Mo |
| `coalescePartitions.initialPartitionNum` | non fixé (Spark part alors de `shuffle.partitions`) |

La valeur de `skewJoin.enabled` n'a pas été relevée (sortie tronquée) et le paramètre n'a pas été testé.

Trois requêtes de référence, choisies pour trois comportements différents :

- **pareto** : jointure de `fact_order_items` avec `dim_product`, agrégation par catégorie, puis fenêtre globale pour le CA cumulé.
- **sessions_rfm** : fenêtre partitionnée par client (`lag` puis somme cumulée) pour les sessions d'achat, puis agrégation par client.
- **jointures** : jointure de `fact_order_items` avec `dim_product` et `dim_seller`, agrégation par (catégorie, état du vendeur).

Résultats de référence vérifiés avant chaque comparaison : pareto 74 lignes, sessions_rfm 94 961 lignes, jointures 512 groupes, et un CA identique de 13 491 302,13 dans les trois cas.

## 2. Méthode de mesure

- **Écriture sans transfert** : chaque requête est exécutée avec `write.format("noop")`, pour ne mesurer que le calcul.
- **Échauffement** : une exécution préalable, hors mesure. Avec l'AQE, le plan final n'existe qu'après exécution.
- **15 exécutions par variante, entrelacées** (A, B, A, B, …) dans la même cellule, pour limiter l'effet des dérives de la machine.
- **Statistiques** : médiane et intervalle interquartile [q1 ; q3], plus min et max.
- **Règle de décision** : un gain ou une perte de temps n'est retenu que si les intervalles [q1 ; q3] des deux variantes ne se recouvrent pas. Sinon : « non distinguable ».
- **Indicateurs structurels**, qui ne dépendent pas du bruit : nombre de jobs, de stages et de tâches exécutés (stages sautés exclus), nombre de shuffles dans le plan final, octets de shuffle écrits (API REST de la Spark UI).
- **Justesse** : les résultats de chaque variante sont comparés à la référence avant la mesure.

## 3. Référence (4.1)

### Structure des plans finaux

| Requête | Shuffles | Broadcasts | BroadcastHashJoin | SortMergeJoin | Fenêtres |
|---|---|---|---|---|---|
| pareto | 2 | 1 | 1 | 0 | 1 |
| sessions_rfm | 1 | 0 | 0 | 0 | 2 |
| jointures | 1 | 2 | 2 | 0 | 0 |

### Mesures de référence (15 exécutions)

| Requête | Médiane [q1 ; q3] (s) | Jobs | Stages | Tâches | Shuffle écrit (Ko) | Entrée (Ko) |
|---|---|---|---|---|---|---|
| pareto | 0,414 [0,384 ; 0,435] | 4 | 4 | 6 | 8,0 | 3 365,0 |
| sessions_rfm | 0,626 [0,604 ; 0,702] | 2 | 2 | 10 | 7 333,6 | 7 817,3 |
| jointures | 0,546 [0,524 ; 0,619] | 4 | 4 | 6 | 34,1 | 3 761,9 |
| plancher : scan d'une colonne | 0,148 [0,138 ; 0,168] | 1 | 1 | 3 | 0 | 3 271,8 |
| plancher : filtre + count | 0,125 [0,112 ; 0,140] | 2 | 2 | 4 | 0,2 | 108,4 |

### Constats sur les plans

- Les trois plans lisent seulement les colonnes utiles de Parquet et poussent le filtre `is_sale = true` dans le scan.
- Les dimensions sont envoyées en broadcast dès la planification ; l'AQE ne change pas la stratégie de jointure ici. Il regroupe les 200 partitions de shuffle (`AQEShuffleRead coalesced`).
- Les agrégations se font en deux temps (partiel avant le shuffle, final après). Dans pareto et jointures, le shuffle ne transporte donc que les 74 et 512 groupes.
- Dans sessions_rfm, les deux fenêtres ont les mêmes clés de partition et de tri : un seul `Exchange` et un seul tri. Les `HashAggregate` finaux, groupés par la même clé `customer_unique_id`, n'ajoutent pas d'`Exchange`.
- sessions_rfm déplace environ 900 fois plus d'octets que pareto : la fenêtre a besoin de toutes les lignes d'un client avant tout calcul, donc le shuffle précède l'agrégation.
- La fenêtre globale de pareto (`Exchange SinglePartition`) s'applique après l'agrégation, donc à 74 lignes : sans risque ici. Elle deviendrait un goulot si le nombre de groupes agrégés devenait très grand.
- Les 7 tâches après le shuffle de sessions_rfm sont cohérentes avec le calcul de regroupement : environ 7 333 Ko répartis par tranches d'au moins 1 Mo (`minPartitionSize`). Le nombre exact de partitions lues n'a pas été relevé dans la Spark UI.

## 4. Jointure broadcast ou sort-merge (4.2)

Variante forcée : `autoBroadcastJoinThreshold` et `adaptive.autoBroadcastJoinThreshold` à `-1`. Le plan confirme des `SortMergeJoin` à la place des `BroadcastHashJoin`.

| Requête | Variante | Médiane [q1 ; q3] (s) | Jobs | Tâches | Shuffles | Shuffle écrit (Ko) |
|---|---|---|---|---|---|---|
| pareto | broadcast (défaut) | 0,469 [0,441 ; 0,492] | 4 | 6 | 2 | 8,0 |
| pareto | sort-merge forcé | 0,424 [0,400 ; 0,463] | 5 | 9 | 4 | 3 187,2 |
| jointures | broadcast (défaut) | 0,577 [0,505 ; 0,628] | 4 | 6 | 1 | 34,1 |
| jointures | sort-merge forcé | 0,736 [0,687 ; 0,862] | 6 | 11 | 5 | 5 847,8 |

**Constats**

- Chaque `SortMergeJoin` ajoute un `Exchange` de chaque côté : 4 shuffles pour pareto, 5 pour jointures. Dans jointures, la table de faits déjà jointe est redistribuée une seconde fois (par `seller_id`).
- Le shuffle écrit est multiplié par environ 400 (pareto) et environ 170 (jointures).
- jointures : le sort-merge est plus lent d'environ 0,16 s en médiane, soit environ 28 % (intervalles disjoints).
- pareto : non distinguable (intervalles qui se recouvrent). Le signe de l'écart de médianes n'est pas interprété.

**Hypothèse** : l'effet n'apparaît pas pour pareto parce qu'elle n'a qu'une jointure et environ 3 Mo à redistribuer, sous le niveau du bruit. À tester sur un jeu plus gros (étape 13).

## 5. Nombre de partitions de shuffle et AQE (4.3)

| Requête | Variante | Médiane [q1 ; q3] (s) | Tâches | Shuffle écrit (Ko) |
|---|---|---|---|---|
| sessions_rfm | AQE actif, 200 (défaut) | 0,464 [0,413 ; 0,534] | 10 | 7 333,6 |
| sessions_rfm | AQE inactif, 200 | 1,397 [1,219 ; 1,544] | 203 | 7 333,6 |
| sessions_rfm | AQE inactif, 8 | 0,440 [0,417 ; 0,487] | 11 | 7 339,6 |
| sessions_rfm | AQE actif, 2000 | 0,465 [0,433 ; 0,512] | 10 | 7 687,1 |
| jointures | AQE actif, 200 (défaut) | 0,394 [0,385 ; 0,467] | 6 | 34,1 |
| jointures | AQE inactif, 200 | 0,744 [0,698 ; 0,758] | 205 | 34,1 |
| jointures | AQE inactif, 8 | 0,498 [0,472 ; 0,544] | 13 | 16,8 |
| jointures | AQE actif, 2000 | 0,433 [0,392 ; 0,459] | 6 | 49,4 |

**Constats**

- Sans AQE, avec 200 partitions, la requête est nettement plus lente (environ 3 fois pour sessions_rfm, environ 1,9 fois pour jointures) à volume de shuffle identique : 203 et 205 tâches contre 10 et 6.
- Avec l'AQE actif, partir de 200 ou de 2000 partitions donne les mêmes tâches (10 et 6) et des temps non distinguables.
- À 8 partitions sans AQE : non distinguable de la référence pour sessions_rfm ; pour jointures, 0,498 contre 0,394, avec une marge de 5 ms entre les intervalles (q3 = 0,467, q1 = 0,472), donc à la limite de la règle.
- Le volume de shuffle écrit varie légèrement avec le nombre de partitions (par exemple 34,1 Ko, 16,8 Ko et 49,4 Ko pour jointures à 200, 8 et 2000 partitions).

**Hypothèse** : le surcoût sans AQE tient au nombre de tâches et de blocs de shuffle à récupérer, non au volume.

**Raisonnement sur un volume 1 000 fois plus grand (non mesuré)** : environ 7 Go de shuffle donneraient des partitions de 37 Mo avec 200 partitions (raisonnable) et d'environ 900 Mo avec 8 (trop lourd). L'AQE regroupe des partitions mais n'en crée pas : la valeur de départ doit donc être large.

## 6. Cache (4.4)

Scénario : trois agrégats calculés à partir de la même base de ventes (CA par catégorie ; nombre de lignes et CA par vendeur ; prix médian approché par catégorie).

| Variante | Médiane [q1 ; q3] (s) | Matérialisation (s) | Mémoire (Ko) |
|---|---|---|---|
| sans cache | 1,307 [1,239 ; 1,380] | n/a | n/a |
| cache complet (14 colonnes) | 1,740 [1,639 ; 1,793] | 1,344 | 14 897 |
| cache projeté (3 colonnes) | 0,869 [0,812 ; 0,928] | 0,553 | 1 969,4 |

Une première mesure, sur deux variantes seulement (sans cache 1,205 s, cache complet 1,631 s, matérialisation 1,282 s), donnait le même sens. Elle avait fait estimer à environ 5 le nombre d'agrégats nécessaires pour amortir le cache complet.

**Constats**

- Le cache complet est plus lent que l'absence de cache (environ +0,43 s, +33 %, intervalles disjoints).
- Le cache projeté est plus rapide que l'absence de cache (environ -0,44 s, -34 %, intervalles disjoints) et occupe environ 7,6 fois moins de mémoire que le cache complet.
- Dans ce montage, la seule différence entre cache complet et cache projeté est l'ensemble des colonnes mises en cache : l'écart leur est attribuable.
- Les résultats des agrégats sont identiques avec et sans cache.

**Point d'attention** : Spark remplace par un cache tout DataFrame dont le plan logique est identique à celui d'un DataFrame mis en cache, même construit indépendamment. Un contrôle « sans cache » fait pendant qu'un cache existe lit donc le cache. De même, compter les `FileScan` dans un plan ne distingue rien, car le plan d'un `InMemoryTableScan` affiche aussi les scans de la relation cachée. L'indicateur fiable est le nombre de `InMemoryTableScan`.

**Pourquoi le cache ne remplace pas une table Gold** : il vit dans la mémoire de la session Spark, disparaît avec elle, n'est pas partagé entre notebooks ni avec les outils de BI, et peut être évincé sous pression mémoire. Une table Parquet persiste et sert de contrat.

## 7. RDD : `groupByKey` contre `reduceByKey` (4.5)

CA par catégorie, à partir des mêmes paires (catégorie, prix), comparé au `groupBy` DataFrame.

| Variante | Médiane [q1 ; q3] (s) | Jobs | Tâches | Shuffle écrit (Ko) |
|---|---|---|---|---|
| RDD `groupByKey` | 0,996 [0,926 ; 1,057] | 2 | 7 | 355,1 |
| RDD `reduceByKey` | 0,931 [0,902 ; 0,991] | 2 | 7 | 2,2 |
| DataFrame `groupBy` | 0,443 [0,381 ; 0,522] | 3 | 5 | 5,9 |

**Constats**

- Les trois méthodes donnent les mêmes 74 clés et le même CA (écart maximal de 0,000000 avec le DataFrame).
- Le shuffle de `groupByKey` est environ 160 fois plus gros que celui de `reduceByKey` (355,1 Ko contre 2,2 Ko).
- `groupByKey` et `reduceByKey` sont non distinguables en temps ici (intervalles qui se recouvrent).
- Le DataFrame est environ 2,1 fois plus rapide que les deux variantes RDD (intervalles disjoints).
- `toDebugString` montre la même forme pour les deux variantes (un `ShuffledRDD`) : la combinaison côté map de `reduceByKey` n'y est pas visible. La preuve est dans les octets de shuffle.

**Hypothèses non testées** : la différence de volume vient de la combinaison locale avant shuffle de `reduceByKey` ; l'écart avec le DataFrame vient en partie du passage des lignes vers Python (`javaToPython`) et de l'exécution des fonctions Python.

## 8. Décisions pour le pipeline

1. Garder l'AQE actif et les valeurs par défaut (200 partitions) : le réglage manuel testé n'apporte aucun gain démontré, et désactiver l'AQE est coûteux.
2. Garder le broadcast automatique pour les dimensions, tant qu'elles restent sous 10 Mo. Surveiller leur taille : au-delà, Spark bascule en sort-merge et le shuffle augmente.
3. Mettre en cache uniquement des colonnes projetées, quand le même DataFrame sert à plusieurs actions. Libérer avec `unpersist`.
4. Préférer l'API DataFrame au RDD pour les agrégations. Si un RDD est nécessaire, utiliser `reduceByKey` plutôt que `groupByKey`.
5. Conserver l'ordre de grandeur de ces indicateurs dans les tests de régression de performance (étapes ultérieures).

## 9. Limites

- Volume faible (environ 10 Mo), une seule machine, 8 cœurs : les conclusions ne se transposent pas à de grands volumes sans nouvelle mesure.
- **Variabilité entre cellules** : la même configuration (jointures, broadcast par défaut, AQE actif, 200) a donné 0,577 [0,505 ; 0,628] au test 4.2 et 0,394 [0,385 ; 0,467] au test 4.3, intervalles disjoints. De même, sessions_rfm : 0,427 (5 exécutions) puis 0,626 (15 exécutions). La cause n'est pas établie. Seules les comparaisons faites dans la même cellule, en alternant les variantes, sont retenues.
- 15 exécutions par variante et une seule requête ou un seul scénario par test.
- Plusieurs mécanismes cités plus haut restent des hypothèses (voir les sections concernées).

## 10. Points ouverts

- Insérer les captures de la Spark UI : graphe SQL de `sessions_rfm`, liste des stages, métrique « number of partitions » de l'`AQEShuffleRead`. **À compléter.**
- Étape 13 : refaire les comparaisons broadcast contre sort-merge et partitions de shuffle sur un jeu répliqué (données synthétiques, clairement étiquetées), et revoir le partitionnement des tables Gold.
- `skewJoin` : non testé.