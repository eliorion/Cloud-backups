# fleet bucket spec — the SINGLE source of truth for Garage S3 buckets + keys.
# Read by `scripts/fleet buckets`. NOT a secret: bucket and FIELD NAMES only, the
# key material itself lives encrypted in secrets/s3-keys.enc.yaml (workstation key
# only). Commit this file — `fleet buckets add` appends to it.
#
#   bucket : key-name : id-field : secret-field
#
# One DEDICATED key per bucket — a leaked key exposes only its own cluster's
# backups, and a compromised prod consumer cannot reach another cluster's bucket.
# The id/secret fields are the flat keys inside secrets/s3-keys.enc.yaml.
# Add a bucket with `fleet buckets add <bucket>`, not by hand.
homelab-staging-etcd-backup : etcd-key       : s3_etcd_id       : s3_etcd_secret
cnpg-staging-asp            : cnpg-asp-key   : s3_cnpg_asp_id   : s3_cnpg_asp_secret
cnpg-staging-fbref          : cnpg-fbref-key : s3_cnpg_fbref_id : s3_cnpg_fbref_secret
cnpg-staging-ai-gateway : cnpg-staging-ai-gateway-key : s3_cnpg_staging_ai_gateway_id : s3_cnpg_staging_ai_gateway_secret
cnpg-staging-n8n : cnpg-staging-n8n-key : s3_cnpg_staging_n8n_id : s3_cnpg_staging_n8n_secret
cnpg-staging-nextcloud : cnpg-staging-nextcloud-key : s3_cnpg_staging_nextcloud_id : s3_cnpg_staging_nextcloud_secret
