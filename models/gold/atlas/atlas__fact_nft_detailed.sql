{{ config(
    materialized = 'view',
    secure = false,
    tags = ['atlas']
) }}


WITH nft_detailed AS (
    SELECT
        day,
        receiver_id,
        tokens,
        all_transfers,
        owners,
        transactions,
        mints,
        inserted_timestamp,
        modified_timestamp
    FROM {{ ref('silver__atlas_nft_detailed') }}
)

SELECT 
    *
FROM nft_detailed