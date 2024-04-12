{{ config(
    materialized = 'incremental',
    merge_exclude_columns = ["inserted_timestamp"],
    cluster_by = ['block_timestamp::DATE'],
    unique_key = 'transfers_id',
    incremental_strategy = 'merge',
    tags = ['curated']
) }}

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
), 

--------------------------------    NFT Transfers    --------------------------------
nft_transfers AS (
    SELECT
        block_id,
        signer_id,
        block_timestamp,
        tx_hash,
        action_id,
        TRY_PARSE_JSON(REPLACE(b.value, 'EVENT_JSON:')) AS DATA,
        receiver_id AS contract_id,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        actions_events
        JOIN LATERAL FLATTEN(
            input => logs
        ) b
    WHERE
        DATA :event IN (
            'nft_transfer',
            'nft_mint'
        )
),
--------------------------------        FINAL      --------------------------------
nft_final AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        contract_id :: STRING AS contract_address,
        COALESCE(
            A.value :old_owner_id,
            signer_id
        ) :: STRING AS from_address,
        COALESCE(
            A.value :new_owner_id,
            A.value :owner_id
        ) :: STRING AS to_address,
        A.value :token_ids [0] :: STRING AS token_id,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        nft_transfers
        JOIN LATERAL FLATTEN(
            input => DATA :data
        ) A
    WHERE
        token_id IS NOT NULL
),
FINAL AS (
    SELECT
        block_id,
        block_timestamp,
        tx_hash,
        action_id,
        contract_address,
        from_address,
        to_address,
        token_id,
        _inserted_timestamp,
        _modified_timestamp
    FROM
        nft_final
)
SELECT
    *,
    {{ dbt_utils.generate_surrogate_key(
        ['tx_hash', 'action_id','contract_address','from_address','to_address','token_id']
    ) }} AS transfers_id,
    SYSDATE() AS inserted_timestamp,
    SYSDATE() AS modified_timestamp,
    '{{ invocation_id }}' AS _invocation_id
FROM
    FINAL