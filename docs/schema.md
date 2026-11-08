# Analyse du dataset Olist

## 1. Vue d'ensemble des tables

| Table | Lignes | Colonnes | Grain (une ligne = ...) |
|---|---|---|---|
| orders | 99 441 | 8 | une commande |
| customers | 99 441 | 5 | un client pour une commande |
| ... | ... | ... | ... |

(Les lignes et colonnes viennent du Test A.)

## 2. Schéma relationnel

customers ──(customer_id)──► orders ◄──(order_id)── order_payments
                               ▲  ▲
                               │  └──(order_id)── order_reviews
                         (order_id)
                               │
                          order_items ──(product_id)──► products ──► category_translation
                               │
                          (seller_id)
                               ▼
                            sellers

geolocation ◄── zip_code_prefix ── customers / sellers

## 3. Constats sur la qualité et la structure

### Q1. Identifiant client
- `customer_id` est unique dans `customers` (99 441 valeurs) : il identifie
  un client **pour une commande**, pas une personne.
- `customer_unique_id` identifie la vraie personne : 96 096 valeurs distinctes.
- Conséquence : 99 441 - 96 096 = 3 345 commandes viennent de clients déjà connus.
  Toute analyse par client doit utiliser `customer_unique_id`.
- Preuve : un même `customer_unique_id` apparaît avec plusieurs `customer_id`
  (voir la requête ci-dessous).

```python
(tables["customers"]
   .groupBy("customer_unique_id").count()
   .filter("count > 1")
   .orderBy(F.desc("count"))
   .show(5))
```
+--------------------+-----+
|  customer_unique_id|count|
+--------------------+-----+
|8d50f5eadf50201cc...|   17|
|3e43e6105506432c9...|    9|
|ca77025e7201e3b30...|    7|
|1b6c7548a2a1f9037...|    7|
|6469f99c1f9dfae77...|    7|
+--------------------+-----+
only showing top 5 rows


### Q2. Grain des tables de détail
- X commandes sur Y ont plus d'une ligne dans order_items, et Z ont plus d'un
  paiement dans order_payments.
- Conséquence : joindre order_items et order_payments directement duplique les
  lignes et gonfle le CA de N %. Il faut agréger chaque table au grain
  « une ligne par commande » avant de les joindre.
- Preuve : 
    # Toutes les colonnes sont en string à ce stade, on caste price pour pouvoir l'additionner
    items = tables["order_items"].withColumn("price", F.col("price").cast("double"))
    paiements = tables["order_payments"]

    # CA correct : somme directe sur order_items
    ca_correct = items.agg(F.sum("price")).first()[0]

    # CA après jointure naïve avec les paiements
    ca_gonfle = items.join(paiements, "order_id").agg(F.sum("price")).first()[0]

    print(f"CA correct : {ca_correct:,.2f}")
    print(f"CA gonflé  : {ca_gonfle:,.2f}")
    print(f"Écart      : {(ca_gonfle / ca_correct - 1) * 100:.1f} %")

    # Output :
    CA correct : 13,591,643.70
    CA gonflé  : 14,209,115.34
    Écart      : 4.5 %

### Q3. Unicité de review_id

- 99 224 lignes, 98 410 review_id distincts, 98 673 order_id distincts.
- Couples (review_id, order_id) = 99 224 : aucun doublon exact.
- review_id non unique : un avis peut être rattaché à plusieurs commandes.
- order_id non unique : certaines commandes ont plusieurs avis (551 lignes en trop).
- Conséquence : en Silver, garder un seul avis par commande (le plus récent).

**Preuve :**

```python
print("Lignes                       :", reviews.count())
print("review_id distincts          :", reviews.select("review_id").distinct().count())
print("Couples (review_id, order_id):", reviews.select("review_id", "order_id").distinct().count())
print("order_id distincts           :", reviews.select("order_id").distinct().count())
```

```text
Lignes                       : 99224
review_id distincts          : 98410
Couples (review_id, order_id): 99224
order_id distincts           : 98673
```
### Q4. Geolocation

- 1 000 163 lignes pour 19 015 zip_code_prefix distincts (~52 lignes par code).
- Conséquence : jointure directe = fan-out massif. En Silver, agréger à une ligne
  par code postal (moyenne lat/lng).

  
### Q5. Orphelins entre order_items et orders
- 0 ligne de order_items sans commande correspondante : intégrité OK dans ce sens.
- 775 commandes sans aucune ligne produit : unavailable 603, canceled 164,
  created 5, invoiced 2, shipped 1.
- 99 % sont des commandes non abouties (cohérent). Les 8 restantes
  (created/invoiced/shipped) sont incohérentes : une commande expédiée sans
  produit.
- Conséquence : en Silver, signaler ces commandes (has_items = false) plutôt
  que les supprimer. Exclure unavailable et canceled des KPI de CA, mais les
  conserver pour mesurer le taux d'annulation.

## 4. Points de vigilance pour Silver
- Toujours utiliser `customer_unique_id` pour les analyses par client.
- Éviter le fan-out lors des jointures (agréger avant de joindre).
- Dédoublonner `geolocation` avant toute jointure.