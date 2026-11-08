# Cadrage du projet

> Phase CRISP-DM : **Business Understanding**
> Projet : Lakehouse e-commerce (PySpark, architecture Médaillon)

## 1. Contexte

Olist est une place de marché brésilienne : des vendeurs proposent leurs produits, les clients commandent, Olist gère le paiement et la livraison. Le dataset public contient environ 100 000 commandes (2016 à 2018) réparties sur 9 tables liées (commandes, clients, lignes produits, paiements, avis, produits, vendeurs, géolocalisation, traduction des catégories).

L'analyse de ces données (voir `docs/schema.md`) a mis en évidence plusieurs particularités qui conditionnent le projet :

- `customer_id` identifie un client **pour une commande** ; le vrai client est `customer_unique_id` (96 096 clients pour 99 441 commandes).
- Les tables de détail ont un grain plus fin que `orders` : une jointure naïve fait gonfler le CA de 4,5 %.
- `order_reviews` doit être lue avec `multiLine`, et une commande peut avoir plusieurs avis.
- `geolocation` contient 1 000 163 lignes pour 19 015 codes postaux : une jointure directe multiplie les clients par environ 152.
- 775 commandes n'ont aucune ligne produit (767 non abouties, 8 incohérentes).

## 2. Objectif du projet

Construire un pipeline Big Data complet et fiable, qui transforme les données brutes en indicateurs décisionnels exploitables, et qui répond aux questions métier ci-dessous.

**Objectifs techniques**

- Ingérer les données brutes sans perte (Bronze), les nettoyer avec des règles documentées (Silver), les modéliser pour l'analyse (Gold).
- Garantir la fiabilité des chiffres (pas de fan-out, pas de doublons).
- Mesurer et documenter la qualité des données.

**Objectifs d'apprentissage**

- Maîtriser Spark Core et Spark SQL sur un cas réel.
- Appliquer les notions du cours : architectures de stockage et de traitement, qualité, gouvernance, optimisation.

## 3. Questions métier

### M1. Ventes par catégorie

**Question** : quelles catégories de produits génèrent l'essentiel du chiffre d'affaires, et comment leur part évolue-t-elle dans le temps ?

| | |
|---|---|
| **KPI** | CA par catégorie, part cumulée (Pareto 80/20), évolution mensuelle |
| **Tables** | `order_items`, `products`, `category_translation`, `orders` |
| **Décision** | Concentrer marketing, stock et négociation vendeurs sur les catégories clés |
| **Point d'attention** | Le CA se calcule depuis `order_items`, jamais après jointure avec les paiements. Valeur de référence : 13 591 643,70 (avant exclusion des commandes non abouties) |

### M2. Délai de livraison par région

**Question** : quel est le délai de livraison réel, et dans quelle mesure dépasse-t-il la date promise, selon la région du client ?

| | |
|---|---|
| **KPI** | Délai moyen (achat vers livraison), taux de retard (livraison après la date estimée), par État |
| **Tables** | `orders`, `customers` (et `geolocation` agrégée pour d'éventuelles cartes) |
| **Décision** | Identifier les régions à problème, revoir les délais annoncés ou les transporteurs |
| **Point d'attention** | Typage des dates en Silver, gestion des commandes non livrées (dates manquantes) |

### M3. Retards et satisfaction

**Question** : les retards de livraison dégradent-ils la satisfaction client ?

| | |
|---|---|
| **KPI** | Note moyenne d'avis des commandes à l'heure contre en retard, par tranche de retard |
| **Tables** | `orders`, `order_reviews` (dédoublonnée : un avis par commande) |
| **Décision** | Chiffrer l'impact d'un retard et justifier un investissement logistique |
| **Point d'attention** | On mesure une **corrélation**, pas une causalité prouvée. À indiquer dans le rapport final |

### M4. Fidélité et valeur client

**Question** : quel est le profil de fidélité des clients, et qui sont les clients à plus forte valeur ?

| | |
|---|---|
| **KPI** | Taux de réachat, segmentation RFM (Récence, Fréquence, Montant) sur `customer_unique_id` |
| **Tables** | `customers`, `orders`, `order_items` |
| **Décision** | Cibler les campagnes de rétention et de réactivation |
| **Point d'attention** | Seulement environ 3 % des commandes viennent de clients récurrents : la dimension Fréquence variera peu, les segments devront être adaptés |

### M5. Annulations et anomalies

**Question** : quel est le taux d'annulation et d'indisponibilité, et quelles commandes présentent des statuts incohérents ?

| | |
|---|---|
| **KPI** | Part des commandes `canceled` et `unavailable`, évolution dans le temps, nombre d'anomalies de statut |
| **Tables** | `orders`, `order_items` |
| **Décision** | Réduire les pertes de ventes et corriger les anomalies à la source |
| **Point d'attention** | Les 775 commandes sans produit sont signalées (`has_items = false`), pas supprimées. Les 8 cas incohérents vont en quarantaine (étape 9) |

### M6. Paiements

**Question** : comment les paiements se répartissent-ils (moyens, échéances), et quel est le lien avec la valeur du panier ?

| | |
|---|---|
| **KPI** | Part par type de paiement, nombre moyen d'échéances, valeur moyenne du panier selon le mode de paiement |
| **Tables** | `order_payments` (agrégée par commande), `orders` |
| **Décision** | Adapter l'offre de paiement (par exemple le paiement en plusieurs fois pour les paniers élevés) |
| **Point d'attention** | 3 % des commandes ont plusieurs paiements : agréger avant de joindre. Question prioritaire à abandonner si le temps manque |

## 4. Lien avec le projet technique

| Question | Couches concernées | Techniques mobilisées |
|---|---|---|
| M1 | Silver, Gold | Agrégation, modèle en étoile, Pareto |
| M2 | Silver, Gold | Typage des dates, jointures, agrégation par région |
| M3 | Silver, Gold | Fonction de fenêtre (`row_number`), jointures |
| M4 | Silver, Gold | Fonctions de fenêtre, RFM sur `customer_unique_id` |
| M5 | Bronze, Silver | Anti-joins, audit qualité, quarantaine |
| M6 | Silver, Gold | Agrégation avant jointure |

## 5. Périmètre

**Inclus**

- Pipeline batch Bronze, Silver, Gold en PySpark.
- Audit et règles de qualité documentés.
- Modèle en étoile et indicateurs répondant à M1 à M6.
- Analyse d'optimisation Spark (étape 4).

**Hors périmètre (version 1.0)**

- Rentabilité : le dataset ne contient aucune donnée de coût, donc pas de marge.
- Prévision de ventes et modèles prédictifs (extension éventuelle en v3.0).
- Traitement temps réel (extension éventuelle en v3.0).

## 6. Choix d'architecture initial

Architecture **Médaillon batch** (Bronze, Silver, Gold). Les données sont historiques, figées, et il n'y a pas d'exigence de faible latence : une architecture Lambda ou Kappa ne se justifie pas à ce stade. Ce choix sera formalisé dans un ADR (étape 15) et pourra être revu si on ajoute du streaming.

## 7. Limites et hypothèses

- **Période limitée** (2016 à 2018) : à vérifier avec les données quelles périodes sont complètes avant de parler de tendance.
- **Pas de coûts** : tous les indicateurs financiers portent sur le CA, pas sur le profit.
- **Corrélation, pas causalité** pour M3.
- **Dataset anonymisé et publié par Olist** : certaines valeurs sont altérées ou masquées, ce qui peut limiter certaines analyses.
- **Hypothèse à confirmer** : les commandes `unavailable` et `canceled` sans produit sont de vraies commandes non abouties (confirmé à 99 % par l'audit, 8 cas restent inexpliqués).

## 8. Critères de réussite

- Les 6 questions reçoivent une réponse chiffrée, reproductible depuis les tables Gold.
- Le CA total de la couche Gold se réconcilie avec celui de la source (aucun fan-out).
- Chaque règle de nettoyage est numérotée, documentée et mesurée (lignes avant et après).
- Le pipeline se relance de bout en bout sans intervention manuelle.

## 9. Prochaines étapes

1. **Étape 1** : couche Bronze (schémas explicites, métadonnées d'ingestion) et audit qualité chiffré.
2. **Étape 2** : couche Silver (règles R1 à Rn, quarantaine préparée).
3. **Étape 3** : couche Gold et réponses à M1 à M6.