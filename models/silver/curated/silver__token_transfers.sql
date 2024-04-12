{{ config(
    materialized = 'incremental',
    merge_exclude_columns = ["inserted_timestamp"],
    cluster_by = ['block_timestamp::DATE'],
    unique_key = 'transfers_id',
    incremental_strategy = 'merge',
    tags = ['curated']
) }}

-- Curation Challenge - 'https://flipsidecrypto.xyz/Hossein/transfer-sector-of-near-curation-challenge-zgM44F'

WITH actions_events AS (

    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        signer_id,
        receiver_id,
        action_name,
        method_name,
        deposit,
        logs,
        receipt_succeeded,
        _inserted_timestamp,
        modified_timestamp as _modified_timestamp
    FROM
        {{ ref('silver__actions_events_function_call_s3') }}
    WHERE
        receipt_succeeded = TRUE
        AND logs [0] IS NOT NULL
        {% if is_incremental() %}
        AND inserted_timestamp >= (
            SELECT
                MAX(inserted_timestamp)
            FROM
                {{ this }}
        )
        {% endif %}
    limit 1000
), 
swaps_raw AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        receipt_object_id,
        token_in,
        signer_id,
        receiver_id,
        amount_in_raw,
        amount_out_raw,
        _inserted_timestamp,
        modified_timestamp AS _modified_timestamp
    FROM
        {{ ref('silver__dex_swaps_v2') }}
    {% if is_incremental() %}
        WHERE
            inserted_timestamp >= (
                SELECT
                    MAX(inserted_timestamp)
                FROM
                    {{ this }}
            )
        {% endif %}
    limit 1000
), 
token_prices AS (
    SELECT
        block_timestamp :: DATE AS DATE,
        token_contract AS token_contract,
        AVG(price_usd) AS price_usd,
        MAX(symbol) AS symbol,
        MAX(inserted_timestamp) AS inserted_timestamp
    FROM
        {{ ref('silver__prices_oracle_s3') }}
    GROUP BY
        1,
        2,
        inserted_timestamp
    {% if is_incremental() %}
    HAVING
        inserted_timestamp >= (
            SELECT
                MAX(inserted_timestamp)
            FROM
                {{ this }}
        )
    {% endif %}
),
metadata AS (
    SELECT
        *
    FROM
        {{ ref('silver__ft_contract_metadata') }}
),
----------------------------    Native Token Transfers   ------------------------------
native_transfers AS (

    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        signer_id AS from_address,
        receiver_id AS to_address,
        IFF(REGEXP_LIKE(deposit, '^[0-9]+$'), deposit, NULL) AS amount_unadjusted,
        --numeric validation (there are some exceptions that needs to be ignored)
        receipt_succeeded,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        {{ ref('silver__transfers_s3') }}
    WHERE
        status = TRUE
        {% if is_incremental() %}
        AND inserted_timestamp >= (
            SELECT
                MAX(inserted_timestamp)
            FROM
                {{ this }}
        )
        {% endif %}
    limit 1000
), 
------------------------------   NEAR Tokens (NEP 141) --------------------------------
swaps AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        receipt_object_id,
        token_in AS contract_address,
        signer_id AS from_address,
        receiver_id AS to_address,
        amount_in_raw :: variant AS amount_unadjusted,
        'swap' AS memo,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        swaps_raw
    UNION ALL
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        receipt_object_id,
        token_in AS contract_address,
        receiver_id AS from_address,
        signer_id AS to_address,
        amount_out_raw :: variant AS amount_unadjusted,
        'swap' AS memo,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        swaps_raw
),
orders AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        receiver_id,
        TRY_PARSE_JSON(REPLACE(g.value, 'EVENT_JSON:')) AS DATA,
        DATA :event AS event,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        actions_events
        JOIN LATERAL FLATTEN(
            input => logs
        ) g
    WHERE
        DATA :event IN ('order_added')
),
orders_final AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        f.value :sell_token :: STRING AS contract_address,
        f.value :owner_id :: STRING AS from_address,
        receiver_id :: STRING AS to_address,
        (
            f.value :original_amount
        ) :: variant AS amount_unadjusted,
        'order' AS memo,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        orders
        JOIN LATERAL FLATTEN(
            input => DATA :data
        ) f
    WHERE
        amount_unadjusted > 0
),
add_liquidity AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        REGEXP_SUBSTR(
            SPLIT.value,
            '"\\d+ ([^"]*)["]',
            1,
            1,
            'e',
            1
        ) :: STRING AS contract_address,
        NULL AS from_address,
        receiver_id AS to_address,
        REGEXP_SUBSTR(
            SPLIT.value,
            '"(\\d+) ',
            1,
            1,
            'e',
            1
        ) :: variant AS amount_unadjusted,
        'add_liquidity' AS memo,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        actions_events,
        LATERAL FLATTEN (
            input => SPLIT(
                REGEXP_SUBSTR(
                    logs [0],
                    '\\["(.*?)"\\]'
                ),
                ','
            )
        ) SPLIT
    WHERE
        logs [0] LIKE 'Liquidity added [%minted % shares'
),
ft_transfers_mints AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        TRY_PARSE_JSON(REPLACE(VALUE, 'EVENT_JSON:')) AS DATA,
        receiver_id AS contract_address,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        actions_events
        JOIN LATERAL FLATTEN(
            input => logs
        ) b
    WHERE
        DATA :event IN (
            'ft_transfer',
            'ft_mint'
        )
),
ft_transfers_mints_final AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        contract_address,
        NVL(
            f.value :old_owner_id,
            NULL
        ) :: STRING AS from_address,
        NVL(
            f.value :new_owner_id,
            f.value :owner_id
        ) :: STRING AS to_address,
        f.value :amount :: variant AS amount_unadjusted,
        f.value :memo :: STRING AS memo,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        ft_transfers_mints
        JOIN LATERAL FLATTEN(
            input => DATA :data
        ) f
    WHERE
        amount_unadjusted > 0
),
nep_transfers AS (
    SELECT
        *
    FROM
        ft_transfers_mints_final
    UNION ALL
    SELECT
        *
    FROM
        orders_final
    UNION ALL
    SELECT
        *
    FROM
        swaps
    UNION ALL
    SELECT
        *
    FROM
        add_liquidity
),
------------------------------  MODELS --------------------------------

native_final AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        'wrap.near' AS contract_address,
        from_address :: STRING,
        to_address :: STRING,
        NULL AS memo,
        'native' as transfer_type,
        amount_unadjusted :: STRING AS raw_amount,
        amount_unadjusted :: FLOAT AS raw_amount_precise,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        native_transfers
),

nep_final AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        contract_address,
        from_address,
        to_address,
        memo,
        'nep141' as transfer_type,
        amount_unadjusted :: STRING AS raw_amount,
        amount_unadjusted :: FLOAT AS raw_amount_precise,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        nep_transfers
),
------------------------------   FINAL --------------------------------
transfer_union AS (

        SELECT
            *
        FROM
            nep_final
        UNION ALL
        SELECT
            *
        FROM
            native_final  
),
price_union AS (
    SELECT 
        t.*,
        b.symbol AS symbol,
        b.decimals AS decimals,
        price_usd AS token_price,
        FROM
    transfer_union t
    LEFT JOIN token_prices
        ON block_timestamp :: DATE = DATE
        AND token_prices.token_contract = t.contract_address
    LEFT JOIN metadata b
        ON token_prices.token_contract = t.contract_address
)
,
FINAL AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        contract_address,
        from_address,
        to_address,
        memo,
        raw_amount,
        raw_amount_precise,
        decimals,
        CASE
            WHEN transfer_type = 'native' THEN raw_amount_precise / 1e24
            WHEN transfer_type = 'nep141' THEN raw_amount_precise / pow(
                10,
                decimals
            )
        END AS amount,
        transfer_type,
        token_price,
        amount * token_price AS amount_usd,
        token_price
        symbol,
        CASE
            WHEN token_price IS NULL THEN 'false'
            ELSE 'true'
        END AS has_price,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        price_union


)
SELECT
    *,
    {{ dbt_utils.generate_surrogate_key(
        ['tx_hash', 'action_id','contract_address','raw_amount','amount_usd','from_address','to_address','memo']
    ) }} AS transfers_id,
    SYSDATE() AS inserted_timestamp,
    SYSDATE() AS modified_timestamp,
    '{{ invocation_id }}' AS _invocation_id
FROM
    FINAL
