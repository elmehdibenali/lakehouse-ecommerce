# Analyse du dataset Olist

Dataset : Brazilian E-Commerce Public Dataset by Olist (9 fichiers CSV, environ 100 000 commandes).
Ce document consigne ce qui a été vérifié sur les données brutes avant d'écrire Bronze et Silver.

## 1. Vue d'ensemble des tables

| Table | Lignes | Colonnes | Grain (une ligne = ...) |
|---|---|---|---|
| orders | 99 441 | 8 | une commande |
| customers | 99 441 | 5 | un client pour une commande |
| order_items | 112 650 | 7 | une ligne produit d'une commande (clé : order_id + order_item_id) |
| order_payments | 103 886 | 5 | un paiement d'une commande (clé : order_id + payment_sequential) |
| order_reviews | 99 224 (*) | 7 | un avis (clé : review_id + order_id) |
| products | 32 951 | 9 | un produit |
| sellers | 3 095 | 4 | un vendeur |
| geolocation | 1 000 163 | 5 | un point GPS (pas de clé) |
| category_translation | 71 | 2 | une catégorie (portugais vers anglais) |

(*) Avec une lecture CSV par défaut, Spark compte 104 162 lignes : les commentaires
multilignes sont coupés en lignes fantômes. Avec `multiLine`, `quote` et `escape`,
on obtient 99 224 lignes (voir Q3).


## 2. Schéma relationnel

```
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
```

`orders` est la table centrale : presque toutes les autres s'y rattachent.

## 3. Constats sur la qualité et la structure

### Q1. Identifiant client

- `customer_id` est unique dans `customers` (99 441 valeurs) : il identifie un client **pour une commande**, pas une personne.
- `customer_unique_id` identifie la vraie personne : 96 096 valeurs distinctes.
- Conséquence : 99 441 - 96 096 = 3 345 commandes viennent de clients déjà connus (environ 3 %). Toute analyse par client doit utiliser `customer_unique_id`.
- Preuve : un même `customer_unique_id` apparaît avec plusieurs `customer_id`.

```python
(tables["customers"]
   .groupBy("customer_unique_id").count()
   .filter("count > 1")
   .orderBy(F.desc("count"))
   .show(5))
```

```text
+--------------------+-----+
|  customer_unique_id|count|
+--------------------+-----+
|8d50f5eadf50201cc...|   17|
|3e43e6105506432c9...|    9|
|ca77025e7201e3b30...|    7|
|1b6c7548a2a1f9037...|    7|
|6469f99c1f9dfae77...|    7|
+--------------------+-----+
```

### Q2. Grain des tables de détail

- 9 803 commandes sur 98 666 (9,9 %) ont plusieurs lignes dans `order_items`.
- 2 961 commandes sur 99 440 (3,0 %) ont plusieurs paiements dans `order_payments`.
- 775 commandes de `orders` n'ont aucune ligne dans `order_items` ; 1 commande n'a aucun paiement.
- Une jointure directe `order_items` x `order_payments` duplique les lignes et gonfle le CA de 4,5 % (14 209 115,34 contre 13 591 643,70).
- Conséquence : agréger chaque table de détail à une ligne par commande (`groupBy("order_id")`) avant toute jointure.

Preuve :

```python
# Comptages
items_par_commande = tables["order_items"].groupBy("order_id").count()
print("Commandes distinctes dans order_items :", items_par_commande.count())
print("Commandes avec plus d'une ligne       :", items_par_commande.filter("count > 1").count())

paiements_par_commande = tables["order_payments"].groupBy("order_id").count()
print("Commandes distinctes dans order_payments :", paiements_par_commande.count())
print("Commandes avec plus d'un paiement        :", paiements_par_commande.filter("count > 1").count())

# Fan-out sur le CA
items = tables["order_items"].withColumn("price", F.col("price").cast("double"))
paiements = tables["order_payments"]

ca_correct = items.agg(F.sum("price")).first()[0]
ca_gonfle = items.join(paiements, "order_id").agg(F.sum("price")).first()[0]

print(f"CA correct : {ca_correct:,.2f}")
print(f"CA gonflé  : {ca_gonfle:,.2f}")
print(f"Écart      : {(ca_gonfle / ca_correct - 1) * 100:.1f} %")
```

```text
Commandes distinctes dans order_items    : 98666
Commandes avec plus d'une ligne          : 9803
Commandes distinctes dans order_payments : 99440
Commandes avec plus d'un paiement        : 2961
CA correct : 13,591,643.70
CA gonflé  : 14,209,115.34
Écart      : 4.5 %
```

Exemple : une commande de 100 payée en deux fois (60 + 40) a 1 ligne produit et 2 paiements. Après jointure, la ligne produit est copiée 2 fois et `SUM(price)` donne 200.

### Q3. Unicité de review_id

**Lecture du CSV**

- Avec les options de lecture par défaut, `review_id` contenait des fragments de commentaires et `order_id` des dates : les colonnes étaient décalées, à cause des retours à la ligne dans les commentaires.
- Solution : lire avec `multiLine`, `quote` et `escape`.

```python
reviews = (spark.read
    .option("header", True)
    .option("multiLine", True)
    .option("quote", '"')
    .option("escape", '"')
    .csv("/home/work/data/raw/olist_order_reviews_dataset.csv"))
```

**Unicité (après lecture correcte)**

- 99 224 lignes, 98 410 `review_id` distincts, 98 673 `order_id` distincts.
- Couples (`review_id`, `order_id`) = 99 224 : aucun doublon exact.
- `review_id` non unique : un même avis peut être rattaché à plusieurs commandes (exemple : `69a1068c...` lié à 3 `order_id`).
- `order_id` non unique : certaines commandes ont plusieurs avis (551 lignes en trop).
- Conséquence : en Silver, garder un seul avis par commande (le plus récent), avec `review_id` comme second critère de tri pour un résultat déterministe.

Preuve :

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

Règle de dédoublonnage validée :

```python
from pyspark.sql import Window

w = Window.partitionBy("order_id").orderBy(F.col("review_answer_timestamp").desc())

reviews_par_commande = (reviews
    .withColumn("rn", F.row_number().over(w))
    .filter("rn = 1")
    .drop("rn"))
```

Résultat : 98 673 lignes et 98 673 `order_id` distincts (une ligne par commande).

### Q4. Geolocation

- 1 000 163 lignes pour 19 015 `zip_code_prefix` distincts (environ 52 lignes par code).
- Jointure directe `customers` x `geolocation` : 99 441 lignes deviennent 15 083 455 (facteur 152, car les clients se concentrent dans les codes postaux qui ont le plus de points GPS).
- Après agrégation par code postal : 19 015 lignes.
- Conséquence : en Silver, agréger `geolocation` à une ligne par code postal (moyenne de la latitude et de la longitude) avant toute jointure.

Preuve :

```python
geo = tables["geolocation"]
clients = tables["customers"]

print("Clients                :", clients.count())
print("Après jointure directe :",
      clients.join(geo, clients.customer_zip_code_prefix == geo.geolocation_zip_code_prefix).count())

geo_agg = (geo
    .withColumn("lat", F.col("geolocation_lat").cast("double"))
    .withColumn("lng", F.col("geolocation_lng").cast("double"))
    .groupBy("geolocation_zip_code_prefix")
    .agg(F.avg("lat").alias("lat"), F.avg("lng").alias("lng")))

print("geo_agg lignes         :", geo_agg.count())
```

```text
Clients                : 99441
Après jointure directe : 15083455
geo_agg lignes         : 19015
```

### Q5. Orphelins entre order_items et orders

- 0 ligne de `order_items` sans commande correspondante : intégrité référentielle correcte dans ce sens.
- 775 commandes sans aucune ligne produit : `unavailable` 603, `canceled` 164, `created` 5, `invoiced` 2, `shipped` 1.
- 99 % (767 sur 775) sont des commandes non abouties, ce qui est cohérent. Les 8 restantes (`created`, `invoiced`, `shipped`) sont incohérentes : une commande expédiée ou facturée sans produit. L'origine n'est pas établie.
- Conséquence : en Silver, signaler ces commandes (`has_items = false`) plutôt que les supprimer. Exclure `unavailable` et `canceled` des KPI de CA, mais les conserver pour mesurer le taux d'annulation. Mettre les 8 cas incohérents en quarantaine.

Preuve :

```python
orders = tables["orders"]
items = tables["order_items"]

orphelins = items.join(orders, "order_id", "left_anti")
print("Lignes orphelines dans order_items :", orphelins.count())

sans_produit = orders.join(items, "order_id", "left_anti")
print("Commandes sans produit :", sans_produit.count())
sans_produit.groupBy("order_status").count().orderBy(F.desc("count")).show()
```

```text
Lignes orphelines dans order_items : 0
Commandes sans produit : 775
+------------+-----+
|order_status|count|
+------------+-----+
| unavailable|  603|
|    canceled|  164|
|     created|    5|
|    invoiced|    2|
|     shipped|    1|
+------------+-----+
```

## 4. Points de vigilance pour Silver

- Toujours utiliser `customer_unique_id` pour les analyses par client ; joindre `orders` à `customers` sur `customer_id`.
- Agréger `order_items`, `order_payments` et `order_reviews` à une ligne par commande avant de joindre.
- Agréger `geolocation` à une ligne par code postal.
- Lire `order_reviews` avec `multiLine`, `quote` et `escape`.
- Pour `order_reviews`, garder l'avis le plus récent (`row_number`) avec un second critère de tri (`review_id`).
- Signaler les commandes sans produit (`has_items = false`) plutôt que les supprimer ; mettre en quarantaine les 8 statuts incohérents.
- Typer proprement les dates et les montants (ils sont lus en `string` au départ).