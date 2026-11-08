# Audit de la couche Bronze

Ce document consigne l'audit qualité des 9 tables Bronze et en déduit les règles de nettoyage de la couche Silver. Les chiffres viennent de `notebooks/01_bronze.ipynb`. Les règles sont des **propositions** : elles seront implémentées et mesurées (lignes avant et après) à l'étape 2.

Principe : le Bronze est une copie fidèle de la source. Il ne corrige rien, il documente.

## 1. Fidélité du Bronze

| Contrôle | Résultat |
|---|---|
| Comptage Bronze = comptage attendu (Test A) | 9 tables sur 9 |
| `exceptAll` source vers Bronze, et Bronze vers source | 0 ligne d'écart dans les deux sens, pour les 9 tables |
| Métadonnées (`ingestion_ts`, `source_file`, `batch_id`) | présentes, sans valeur manquante, un seul `batch_id` par table |
| `order_reviews` : identifiants de longueur différente de 32 | 0 (`review_id` et `order_id`) |

Choix de conception : toutes les colonnes sont lues en `string` avec un schéma explicite, pour que l'audit puisse mesurer les valeurs invalides au lieu de les voir disparaître en `NULL`. Le typage se fait en Silver avec `try_cast`.

**Lecture de `order_reviews`** : les commentaires clients contiennent des retours à la ligne et des guillemets. Sans les options `multiLine`, `quote` et `escape`, Spark compte 104 162 lignes (lignes fantômes, colonnes décalées) au lieu de 99 224.

## 2. Doublons

| Table | Doublons sur la clé | Doublons exacts |
|---|---|---|
| customers, orders, order_items, order_payments, order_reviews, products, sellers, category_translation | 0 | 0 |
| geolocation (pas de clé) | non applicable | **261 831** (26,2 %) |

Pour `geolocation`, supprimer les doublons exacts ne suffit pas : il reste environ 738 000 lignes pour 19 015 codes postaux. Une agrégation par code postal reste nécessaire (voir `schema.md`, Q4).

## 3. Valeurs manquantes

Une valeur est comptée comme manquante si elle est `NULL` ou vide.

| Table | Colonne | Manquants | Verdict |
|---|---|---|---|
| order_reviews | review_comment_title | 87 658 (88,3 %) | normal : commentaire facultatif |
| order_reviews | review_comment_message | 58 256 (58,7 %) | normal : commentaire facultatif |
| orders | order_approved_at | 160 (0,2 %) | normal selon le statut, 14 anomalies sur commandes `delivered` |
| orders | order_delivered_carrier_date | 1 783 (1,8 %) | normal selon le statut, 2 anomalies sur `delivered` |
| orders | order_delivered_customer_date | 2 965 (3,0 %) | normal selon le statut, 8 anomalies sur `delivered` |
| products | catégorie, longueur du nom, longueur de la description, nombre de photos | 610 chacune (1,9 %) | anormal : ce sont les **mêmes 610 produits** |
| products | poids et 3 dimensions | 2 chacune | anormal |

### Dates de `orders` selon le statut

| Statut | Total | Sans approbation | Sans date transporteur | Sans date de livraison |
|---|---|---|---|---|
| delivered | 96 478 | 14 | 2 | 8 |
| shipped | 1 107 | 0 | 0 | 1 107 |
| canceled | 625 | 141 | 550 | 619 |
| unavailable | 609 | 0 | 609 | 609 |
| invoiced | 314 | 0 | 314 | 314 |
| processing | 301 | 0 | 301 | 301 |
| created | 5 | 5 | 5 | 5 |
| approved | 2 | 0 | 2 | 2 |

- **23 commandes `delivered` distinctes** ont au moins une date manquante (une commande cumule deux manques). C'est une incohérence : une commande livrée doit avoir ses dates.
- **1 107 commandes `shipped` sans livraison** : leurs dates d'achat vont du 2016-09-04 au 2018-09-03, alors que la dernière commande du dataset date du 2018-10-17. Elles ne peuvent pas toutes être « en transit ». La cause n'est pas établie par les données.
- 6 commandes `canceled` ont une date de livraison (625 − 619) : à examiner.

## 4. Formats et valeurs aberrantes

**Formats** : 0 valeur non vide non convertible sur les 24 colonnes contrôlées (dates, entiers, décimaux). Limite : `try_cast` accepte plusieurs écritures de date, ce contrôle prouve que les valeurs sont lisibles, pas qu'elles ont toutes le même format.

**Modalités** : `review_score` entre 1 et 5 uniquement ; 8 statuts de commande cohérents ; `payment_type` contient une modalité inattendue, `not_defined`.

**Plages et aberrations :**

| Constat | Chiffre | Classe |
|---|---|---|
| `payment_value` ≤ 0 | 9 lignes | aberrante |
| `payment_installments` = 0 | 2 lignes (montants valides : 58,69 et 129,94) | aberrante |
| `payment_type` = `not_defined` | 3 lignes | modalité inattendue |
| `freight_value` = 0 | 383 lignes | probablement normal (livraison gratuite), non confirmé |
| `product_weight_g` = 0 | 4 produits, tous de la catégorie `cama_mesa_banho` | aberrante |
| Points GPS hors du rectangle du Brésil (lat −34..6, lng −74..−34) | 42 sur 1 000 163 | aberrante |
| `price` | min 0,85, max 6 735, aucune valeur ≤ 0 | cohérent |

**Paiements anormaux** : 11 lignes pour 10 commandes. 6 lignes `voucher` à 0,00 (4 commandes `delivered`, 1 commande `shipped` présente sur 2 lignes), 3 lignes `not_defined` à 0,00 (toutes sur des commandes `canceled`), 2 lignes `credit_card` à 0 échéance. Un paiement à 0,00 ne fausse pas le CA mais fausse les comptages et la répartition des types de paiement (M6).

Le rectangle englobant le Brésil est une approximation : un point hors rectangle est certainement faux, un point dedans n'est pas forcément correct.

## 5. Période couverte

Commandes du **2016-09-04 au 2018-10-17**.

| Période | Commandes | Utilisable pour une tendance ? |
|---|---|---|
| 2016-09 | 4 | non |
| 2016-10 | 324 | non (trop faible) |
| 2016-11 | aucune | non (mois absent) |
| 2016-12 | 1 | non |
| 2017-01 à 2018-08 | de 800 à 7 544 par mois | **oui (20 mois continus)** |
| 2018-09 | 16 | non |
| 2018-10 | 4 | non |

## 6. Intégrité référentielle

**Enfants sans parent :**

| Lien | Orphelins |
|---|---|
| orders vers customers | 0 |
| order_items vers orders | 0 |
| order_items vers products | 0 |
| order_items vers sellers | 0 |
| order_payments vers orders | 0 |
| order_reviews vers orders | 0 |
| products vers category_translation | **13** (2 catégories : `pc_gamer` 3, `portateis_cozinha_e_preparadores_de_alimentos` 10) |
| customers vers geolocation | **278** |
| sellers vers geolocation | **7** |

**Parents sans enfant :** 775 commandes sans ligne produit, 1 commande sans paiement, 768 commandes sans avis (normal, l'avis est facultatif), 0 client sans commande, 0 produit jamais vendu, 0 vendeur sans vente.

Les 13 produits sans traduction s'ajoutent aux 610 produits sans catégorie : les deux cas sont à traiter pour la question M1.

## 7. Cohérence des dates

| Contrôle | Commandes concernées |
|---|---|
| approbation avant achat | 0 |
| livraison avant achat | 0 |
| date estimée avant achat | 0 |
| remise au transporteur avant approbation | **1 359** (écart médian 17,2 h, maximum environ 4 109 h, soit 171 jours) |
| livraison client avant remise au transporteur | **23** |
| avis créé avant l'achat (comparaison à la seconde) | 74 |
| avis créé un jour avant le jour d'achat | **64** |

Les dates de création d'avis sont à minuit : la comparaison à la seconde compte à tort 10 avis postés le jour même de l'achat. La comparaison au niveau du jour (64) est la bonne mesure.

Les causes de ces écarts ne sont pas établies (processus réel, décalage entre systèmes, saisie). Impact métier : un délai « transporteur vers client » peut être négatif ou incohérent, donc M2 mesure le délai **achat vers livraison client**.

## 8. Règles proposées pour Silver

| Règle | Problème traité | Action proposée | Traitement |
|---|---|---|---|
| **R1** | Tout est en `string` | Typer avec `try_cast` : dates en `timestamp`, montants en `double`, entiers en `int`. **Garder les codes postaux en `string`** (un code `01046` deviendrait `1046`) | transformation |
| **R2** | `order_reviews` : 551 avis en trop par commande | Garder l'avis le plus récent par commande (`row_number`), tri sur `review_answer_timestamp` puis `review_id` | dédoublonnage |
| **R3** | `order_reviews` : commentaires manquants | Ajouter `has_comment` ; ne pas supprimer | indicateur |
| **R4** | `geolocation` : 261 831 doublons exacts, 42 points hors Brésil, 1 ligne par point | Dédoublonner, filtrer les points hors Brésil **avant** d'agréger, puis une ligne par code postal | dédoublonnage, filtre, agrégation |
| **R5** | 775 commandes sans produit | Ajouter `has_items = false`, exclure `unavailable` et `canceled` des KPI de CA, les garder pour le taux d'annulation | indicateur |
| **R6** | 23 commandes `delivered` avec date manquante, 8 commandes sans produit en statut `created`, `invoiced` ou `shipped` | Écarter vers une table de quarantaine avec le motif | quarantaine |
| **R7** | 1 107 commandes `shipped` sans livraison depuis longtemps | Ajouter un indicateur d'ancienneté relatif à la date de fin du dataset (2018-10-17), pas à la date du jour. Seuil à fixer et à documenter comme hypothèse | indicateur |
| **R8** | 610 produits sans catégorie, 13 produits avec une catégorie non traduite | Catégorie `unknown` pour les 610 ; ajouter une traduction manuelle pour les 2 catégories manquantes | complétion |
| **R9** | 4 produits à poids 0, 2 produits sans poids ni dimensions | Mettre le poids à `NULL` quand il vaut 0 | nettoyage |
| **R10** | 9 paiements ≤ 0, 3 `not_defined`, 2 à 0 échéance | Signaler (`is_anomalous_payment`), ne pas supprimer ; classer `not_defined` en `unknown` | indicateur |
| **R11** | 1 359 + 23 + 64 incohérences de dates | Ajouter des indicateurs d'incohérence ; calculer le délai de livraison comme achat vers livraison client | indicateur |
| **R12** | 278 clients et 7 vendeurs sans géolocalisation | Joindre `geolocation` en `left join` | jointure |
| **R13** | Fan-out des tables de détail | Agréger `order_items`, `order_payments` et `order_reviews` à une ligne par commande avant de joindre | agrégation |
| **R14** | Mois hors de la fenêtre 2017-01 à 2018-08 | Ajouter `in_analysis_window` ; exclure ces mois des courbes de tendance sans supprimer les lignes | indicateur |

**Règle générale de traitement** : on **supprime** peu (doublons stricts, points GPS aberrants), on **signale** beaucoup (indicateurs booléens), et on **met en quarantaine** les lignes incohérentes avec leur motif, pour que rien ne disparaisse sans trace.

## 9. Impact sur les questions métier

| Question | Points d'attention issus de l'audit |
|---|---|
| M1 (catégories) | 610 produits sans catégorie, 13 sans traduction, tendances sur 2017-01 à 2018-08 seulement |
| M2 (délais) | mesurer achat vers livraison client ; 2 965 commandes sans date de livraison ; 23 `delivered` incohérentes |
| M3 (retards et avis) | un avis par commande (R2) ; 64 avis antérieurs au jour d'achat |
| M4 (fidélité) | utiliser `customer_unique_id` |
| M5 (annulations) | 775 commandes sans produit ; 1 107 `shipped` anciennes à qualifier |
| M6 (paiements) | 11 lignes de paiement anormales, agréger par commande avant de joindre |

## 10. Limites de l'audit

- Les causes des incohérences ne sont pas établies : l'audit constate et quantifie, il n'explique pas.
- Le contrôle de format ne vérifie pas l'homogénéité des écritures de date.
- Le rectangle du Brésil est approximatif.
- Les seuils (60 jours pour `shipped`, plage de dates exploitable) sont des hypothèses de travail.
- Aucune vérification des valeurs textuelles (villes, États) n'a été faite : à ajouter si une analyse géographique est menée.