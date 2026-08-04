from pyspark.sql import SparkSession, functions as F
from pyspark.sql.window import Window

spark = SparkSession.builder \
    .appName("FEATSRV-PIT-Join") \
    .config("spark.sql.execution.arrow.pyspark.enabled", "true") \
    .getOrCreate()

# Load data
policies = spark.read.parquet("data/raw/policies.parquet")
address = spark.read.parquet("data/raw/address_history.parquet")
claims = spark.read.parquet("data/raw/claims.parquet")

# Join claims with policies (static attributes)
training = claims.join(policies, "policy_id", "left")

# Point-in-time join with address history
# For each claim, pick the address where valid_from <= report_date < valid_to
training.createOrReplaceTempView("training")
address.createOrReplaceTempView("address")

pit_sql = """
SELECT t.*, a.address
FROM training t
LEFT JOIN address a
  ON t.policy_id = a.policy_id
  AND a.valid_from <= t.report_date
  AND (a.valid_to IS NULL OR a.valid_to > t.report_date)
"""

result = spark.sql(pit_sql)

# Show results
print(f"Total rows: {result.count()}")
result.select("claim_id", "policy_id", "report_date", "initial_premium", "region", "address", "claim_amount", "fraud_flag") \
      .show(5, truncate=False)

spark.stop()
