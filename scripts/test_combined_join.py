import pandas as pd
from feast import FeatureStore

store = FeatureStore(repo_path=".")

# Load claims and pick 3 test claims
claims = pd.read_parquet("data/raw/claims.parquet")
sample = claims.head(3)[["claim_id", "policy_id", "report_date", "fraud_flag"]]
sample["event_timestamp"] = pd.to_datetime(sample["report_date"])
sample = sample[["claim_id", "policy_id", "event_timestamp", "fraud_flag"]]

print("Entity DataFrame (labels):")
print(sample)

# Features from both policy and claim views
features = [
    "policy_features:initial_premium",
    "policy_features:region",
    "address_features:address",
    "claim_features:claim_amount",
]

training_df = store.get_historical_features(
    entity_df=sample,
    features=features,
).to_df()

print("\nCombined Point‑in‑Time Training Set:")
print(training_df)
print(f"\nRows: {len(training_df)}, Missing values: {training_df.isna().sum().sum()}")
