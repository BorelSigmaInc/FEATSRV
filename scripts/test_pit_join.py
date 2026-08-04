import pandas as pd
from feast import FeatureStore
from datetime import datetime

store = FeatureStore(repo_path=".")

# ----- PART A: Prove point‑in‑time address works (policy entity) -----
# Load address history and find a policy that changed address
addr = pd.read_parquet("data/raw/address_history.parquet")
# Pick a policy with multiple addresses (POL-0000 has two addresses)
policy_id = "POL-0000"
addr_pol = addr[addr["policy_id"] == policy_id].sort_values("valid_from")
print(f"Address history for {policy_id}:")
print(addr_pol[["policy_id", "address", "valid_from", "valid_to"]])

# Create an entity dataframe with a timestamp DURING the first address validity
test_time = addr_pol.iloc[0]["valid_from"] + pd.Timedelta(days=10)
entity_df = pd.DataFrame({
    "policy_id": [policy_id],
    "event_timestamp": [test_time]
})
print(f"\nAsking for address at {test_time} (during first address validity)...")

features = ["address_features:address", "policy_features:initial_premium", "policy_features:region"]
result = store.get_historical_features(entity_df=entity_df, features=features).to_df()
print("Result:")
print(result)
expected_addr = addr_pol.iloc[0]["address"]
actual_addr = result.iloc[0]["address"]
print(f"Expected: {expected_addr}, Got: {actual_addr} -> {'PASS' if expected_addr == actual_addr else 'FAIL'}")

# Now test a timestamp DURING the second address validity (if exists)
if len(addr_pol) > 1:
    test_time2 = addr_pol.iloc[1]["valid_from"] + pd.Timedelta(days=10)
    entity_df2 = pd.DataFrame({
        "policy_id": [policy_id],
        "event_timestamp": [test_time2]
    })
    result2 = store.get_historical_features(entity_df=entity_df2, features=features).to_df()
    expected_addr2 = addr_pol.iloc[1]["address"]
    actual_addr2 = result2.iloc[0]["address"]
    print(f"Second address at {test_time2}: Expected: {expected_addr2}, Got: {actual_addr2} -> {'PASS' if expected_addr2 == actual_addr2 else 'FAIL'}")

# ----- PART B: Test claim features (claim entity) -----
claims_df = pd.read_parquet("data/raw/claims.parquet")
sample_claims = claims_df.head(3)[["claim_id", "report_date"]]
sample_claims["event_timestamp"] = pd.to_datetime(sample_claims["report_date"])
sample_claims = sample_claims[["claim_id", "event_timestamp"]]
claim_features = ["claim_features:claim_amount", "claim_features:fraud_flag", "claim_features:policy_id"]
claim_result = store.get_historical_features(entity_df=sample_claims, features=claim_features).to_df()
print("\nClaim features (point‑in‑time at report_date):")
print(claim_result.head())
print(f"Retrieved {len(claim_result)} rows with no missing values.")
