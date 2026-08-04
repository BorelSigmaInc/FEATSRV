Service 1: Point‑in‑Time Training Set
--------------------------------------
Upload a CSV/JSON/Excel file with columns:
  claim_id / policy_id, event_timestamp
The API returns a leakage‑free DataFrame ready for model training.

Input:  sample_input.csv
Output: sample_output.json (first 3 rows of the result)
