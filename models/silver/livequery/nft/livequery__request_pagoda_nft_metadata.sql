{{ config(
    materialized = 'incremental',
    unique_key = 'nft_id',
    incremental_strategy = 'delete+insert',
    tags = ['livequery']
) }}

WITH nfts_minted AS (

    SELECT
        receiver_id AS contract_account_id,
        token_id,
        MD5(
            receiver_id || token_id
        ) AS nft_id,
        COALESCE(
            _inserted_timestamp,
            _load_timestamp
        ) AS _inserted_timestamp
    FROM
        {{ ref('silver__standard_nft_mint_s3') }}
),
have_metadata AS (
    SELECT
        contract_account_id,
        token_id,
        nft_id,
        _inserted_timestamp
    FROM
        {{ this }}
),
final_nfts_to_request AS (
    SELECT
        *
    FROM
        nfts_minted
    EXCEPT
    SELECT
        *
    FROM
        have_metadata
),
lq_request AS (
    SELECT
        contract_account_id,
        token_id,
        nft_id,
        'https://near-mainnet.api.pagoda.co/eapi/v1/NFT/' || contract_account_id || '/' || token_id AS res_url,
        ethereum.streamline.udf_api(
            'GET',
            res_url,
            { 
                'x-api-key': '{{ var('PAGODA_API_KEY', Null )}}',
                'Content-Type': 'application/json'
            },
            {}
        ) AS lq_response,
        SYSDATE() AS _request_timestamp,
        _inserted_timestamp
    FROM
        final_nfts_to_request
    LIMIT
        {{ var(
            'sql_limit', 10
        ) }}
), 
FINAL AS (
    SELECT
        contract_account_id,
        token_id,
        nft_id,
        res_url,
        lq_response,
        lq_response :data :message IS NULL AS call_succeeded,
        _request_timestamp,
        _inserted_timestamp
    FROM
        lq_request
)
SELECT
    *
FROM
    FINAL
