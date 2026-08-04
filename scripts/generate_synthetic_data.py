import pandas as pd
import numpy as np
from faker import Faker
from datetime import datetime, timedelta
import os

fake = Faker()
np.random.seed(42)
N_POLICIES = 500

# ------------------- 1. Policies (slowly changing dimension) -------------------
policies = []
for i in range(N_POLICIES):
    pol_id = f"POL-{i:04d}"
    inception = fake.date_between(start_date='-2y', end_date='-1y')
    premium = round(np.random.uniform(300, 2000), 2)
    policies.append({
        "policy_id": pol_id,
        "inception_date": inception,
        "initial_premium": premium,
        "region": fake.state_abbr()
    })

df_policies = pd.DataFrame(policies)
df_policies["inception_date"] = pd.to_datetime(df_policies["inception_date"])

# Address changes (SCD Type 2): each policy gets 0-2 address changes
address_rows = []
for _, pol in df_policies.iterrows():
    current_date = pol["inception_date"]
    address = fake.street_address()
    address_rows.append({
        "policy_id": pol["policy_id"],
        "address": address,
        "valid_from": current_date,
        "valid_to": None  # current
    })
    for _ in range(np.random.choice([0, 1, 2], p=[0.3, 0.5, 0.2])):
        new_date = current_date + timedelta(days=np.random.randint(30, 300))
        old_row = address_rows[-1]
        old_row["valid_to"] = new_date
        new_address = fake.street_address()
        address_rows.append({
            "policy_id": pol["policy_id"],
            "address": new_address,
            "valid_from": new_date,
            "valid_to": None
        })
        current_date = new_date

df_address = pd.DataFrame(address_rows)
df_address["valid_from"] = pd.to_datetime(df_address["valid_from"])
df_address["valid_to"] = pd.to_datetime(df_address["valid_to"])

# ------------------- 2. Claims -------------------
claims = []
for i in range(N_POLICIES * 2):
    pol_id = fake.random_element(elements=df_policies["policy_id"])
    pol_inception = df_policies[df_policies["policy_id"] == pol_id]["inception_date"].iloc[0]
    occ_date = fake.date_between(start_date=pol_inception, end_date='today')
    report_date = occ_date + timedelta(days=np.random.randint(0, 30))
    claims.append({
        "claim_id": f"CLM-{i:05d}",
        "policy_id": pol_id,
        "occurrence_date": occ_date,
        "report_date": report_date,
        "claim_amount": round(np.random.exponential(2000), 2),
        "fraud_flag": int(np.random.choice([0, 1], p=[0.9, 0.1]))
    })

df_claims = pd.DataFrame(claims)
df_claims["occurrence_date"] = pd.to_datetime(df_claims["occurrence_date"])
df_claims["report_date"] = pd.to_datetime(df_claims["report_date"])

# Convert all datetime columns to microseconds for Spark compatibility
for df in [df_policies, df_address, df_claims]:
    for col in df.select_dtypes(include=['datetime64']).columns:
        df[col] = df[col].dt.as_unit('us')

# ------------------- Save to Parquet -------------------
out_dir = "data/raw"
os.makedirs(out_dir, exist_ok=True)
df_policies.to_parquet(f"{out_dir}/policies.parquet", index=False)
df_address.to_parquet(f"{out_dir}/address_history.parquet", index=False)
df_claims.to_parquet(f"{out_dir}/claims.parquet", index=False)

print("Synthetic data generated:")
print(f"  Policies: {len(df_policies)}")
print(f"  Address changes: {len(df_address)}")
print(f"  Claims: {len(df_claims)}")
print("Files saved to data/raw/")
