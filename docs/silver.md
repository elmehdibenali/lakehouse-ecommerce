# Couche Silver

Ce document décrit la couche Silver : les règles appliquées aux données du Bronze, leur effet chiffré, les lignes mises en quarantaine, la réconciliation du chiffre d'affaires et les validations passées. Les règles R1 à R14 viennent de `docs/audit_bronze.md`. Les chiffres viennent de `notebooks/02_silver.ipynb`.

Principe : on supprime peu, on signale beaucoup (indicateurs booléens), et on met en quarantaine les lignes incohérentes avec leur motif, pour que rien ne disparaisse sans trace.

## 1. Inventaire

| Table | Lignes | Colonnes | Rôle |
|---|---|---|---|
| customers | 99 441 | 11 | clients, avec coordonnées et `has_geo` |
| sellers | 3 095 | 10 | vendeurs, avec coordonnées et `has_geo` |
| products | 32 951 | 14 | produits, catégorie anglaise, `is_category_unknown` |
| category_translation | 73 | 6 | traductions, dont 2 manuelles (`is_manual`) |
| geolocation | 19 010 | 4 | une ligne par code postal (latitude et longitude moyennes, `n_points`) |
| orders | 99 410 | 21 | commandes avec indicateurs et délais |
| order_items | 112 626 | 10 | lignes produit |
| order_payments | 103 855 | 12 | paiements avec indicateurs d'anomalie |
| order_reviews | 98 644 | 11 | un avis par commande |
| orders_enriched | 99 410 | 41 | une ligne par commande, prête pour Gold |
| quarantine_orders | 31 | 22 | commandes écartées, avec motif |
| quarantine_order_items | 24 | 10 | lignes produit de ces commandes |
| quarantine_order_payments | 31 | 12 | paiements de ces commandes |
| quarantine_order_reviews | 29 | 11 | avis de ces commandes |

## 2. Règles appliquées

| Règle | Table | Traitement | Résultat |
|---|---|---|---|
| **R1** | les 9 tables | chaînes vides en `NULL`, typage avec `try_cast`, codes postaux gardés en `string` | 0 ligne supprimée, 0 valeur détruite (nombre de `NULL` par colonne identique avant et après) |
| **R2** | order_reviews | un seul avis par commande : le plus récent, puis `review_id` en second critère | 99 224 lignes vers 98 673 (551 écartées) |
| **R3** | order_reviews | indicateur `has_comment` | vrai pour 42 489 avis sur 98 673 |
| **R4** | geolocation | dédoublonnage, filtre des points hors Brésil, une ligne par code postal | 1 000 163 lignes vers 19 010 (738 332 après dédoublonnage, 33 points hors Brésil filtrés) |
| **R5** | orders | `has_items` et `is_sale` (produits, et statut hors `canceled` et `unavailable`) | `is_sale` vrai pour 98 176 commandes ; 767 commandes sans produit conservées |
| **R6** | orders | quarantaine avec motif | 31 commandes : 23 `delivered_missing_date`, 8 `no_items_inconsistent_status` |
| **R7** | orders | `is_shipped_stale` : `shipped` sans livraison depuis plus de 60 jours avant la fin du dataset (2018-10-17) | 1 098 commandes sur 1 106 `shipped` en Silver |
| **R8** | products, category_translation | catégorie `unknown` ; 2 traductions ajoutées à la main | 610 produits `unknown` ; 73 traductions dont 2 manuelles |
| **R9** | products | poids égal à 0 remplacé par `NULL` | 4 produits ; `NULL` de poids passés de 2 à 6 |
| **R10** | order_payments | indicateurs `is_zero_value`, `is_zero_installments`, `is_undefined_type` ; `not_defined` devient `unknown` | 11 lignes signalées, aucune supprimée |
| **R11** | orders | indicateurs d'incohérence de dates, `delivery_days`, `delay_days`, `is_late` | 1 359 transporteur avant approbation, 23 livraison avant transporteur, 6 annulées mais livrées (comptages avant quarantaine) |
| **R12** | customers, sellers | `left join` sur la géolocalisation, indicateur `has_geo` | 279 clients et 7 vendeurs sans coordonnées |
| **R13** | orders_enriched | tables de détail agrégées à une ligne par commande avant les jointures | 99 410 lignes, somme de `n_items` = 112 626 (aucun fan-out) |
| **R14** | orders | indicateur `in_analysis_window` (2017-01 à 2018-08) | 99 064 commandes dans la fenêtre, 346 en dehors |

Retards (R11) : 6 534 commandes en retard sur 96 461 commandes livrées (environ 6,8 %), comparaison au niveau du jour. Ce chiffre inclut quelques commandes annulées mais livrées : M2 devra filtrer sur `order_status = 'delivered'`.

## 3. Quarantaine

| Source | Lignes en Silver | Lignes en quarantaine | Total |
|---|---|---|---|
| orders | 99 410 | 31 | 99 441 |
| order_items | 112 626 | 24 | 112 650 |
| order_payments | 103 855 | 31 | 103 886 |
| order_reviews | 98 644 | 29 | 98 673 |

Motifs des 31 commandes : 23 commandes `delivered` avec au moins une date manquante, et 8 commandes sans produit dont le statut est `created`, `invoiced` ou `shipped`.

Règle d'intégrité : aucune ligne de détail ne référence une commande absente de Silver (0 orphelin dans les 4 liens contrôlés).

## 4. Réconciliation du chiffre d'affaires

| Étape | Montant |
|---|---|
| CA source (Bronze, toutes les lignes) | 13 591 643,70 |
| moins : lignes des commandes en quarantaine | 3 098,61 |
| **CA Silver** | **13 588 545,09** |
| moins : commandes `canceled` et `unavailable` | 97 242,96 |
| **CA des ventes (`is_sale = true`)** | **13 491 302,13** |

Le CA des ventes est le chiffre de référence pour la question M1. La quarantaine représente environ 0,02 % du CA source.

## 5. Validations passées

| Contrôle | Résultat |
|---|---|
| R1 : nombre de `NULL` par colonne identique avant et après typage | 9 tables sur 9 |
| `orders_enriched` : lignes = `order_id` distincts | 99 410 = 99 410 |
| Somme de `n_items` | 112 626, égale au nombre de lignes de `order_items` |
| Intégrité : order_items, order_payments, order_reviews vers orders ; orders vers customers | 0 orphelin dans les 4 liens |
| Commandes sans client | 0 |
| Chiffres de l'audit retrouvés | 775 sans produit, 1 359, 23, 6, quarantaine 23 et 8, 9 paiements ≤ 0, 2 à 0 échéance, 3 `not_defined` |
| Tables relues depuis le disque | 14 dossiers présents, comptages conformes |

## 6. Décisions et hypothèses

- **Quarantaine des 23 commandes `delivered` à date manquante.** Leur retrait coûte 3 098,61 de CA (0,02 %). Alternative défendable : les garder avec un indicateur, puisque les dates manquantes ne changent pas le CA. Choix retenu : les écarter, pour qu'elles ne faussent pas les délais de livraison.
- **Définition de `is_sale`.** Une commande annulée ou indisponible ne génère pas de revenu, même si elle a des lignes produit.
- **Seuil de 60 jours pour `is_shipped_stale`.** Hypothèse de travail. Seules 8 commandes `shipped` passent sous le seuil, donc le choix est peu sensible.
- **Fenêtre d'analyse 2017-01 à 2018-08.** Les autres mois ont trop peu de commandes pour une tendance (voir l'audit).
- **Traductions manuelles.** `pc_gamer` reste `pc_gamer`, et `portateis_cozinha_e_preparadores_de_alimentos` devient `portable_kitchen_and_food_preparers`. Ce sont des traductions du portugais faites à la main, pas des données officielles, tracées par `is_manual`.
- **Géolocalisation par moyenne.** Une moyenne de latitude et de longitude par code postal est une approximation du centre : acceptable pour une carte, pas pour un calcul de distance précis. Le filtre des points aberrants passe avant la moyenne, car un seul point extrême la fausserait.
- **Rectangle du Brésil approximatif.** Un point hors du rectangle est certainement faux, un point dedans n'est pas forcément correct.

## 7. Points ouverts

- **303 commandes dont le paiement diffère de la somme produits et frais de plus d'un centime**, sur 98 642 comparables (0,3 %). La cause n'est pas établie. `items_total` et `payment_total` restent deux mesures distinctes dans `orders_enriched`.
- **5 codes postaux perdus** par le filtre de R4 (19 015 codes avant, 19 010 après), ce qui explique un client de plus sans coordonnées (279 contre 278 dans l'audit).
- **1 commande sans paiement** et **766 commandes sans avis** : cohérent avec l'audit (l'avis est facultatif).
- **Variantes d'accents dans les noms de ville** non vérifiées (seules la casse et les espaces l'ont été). À contrôler avant toute analyse par ville.
- **Journal des règles** : les colonnes « avant » et « après » n'ont pas le même sens selon la règle (lignes restantes ou lignes signalées). Le tableau de la section 2 est la lecture de référence.

## 8. Entrées pour Gold

La table `orders_enriched` contient une ligne par commande, avec `customer_unique_id`, l'État du client, les totaux produits, frais et paiements, le score d'avis, les délais et tous les indicateurs. Gold s'appuie dessus pour les questions M2 à M6, et sur `order_items` joint à `products` pour M1.