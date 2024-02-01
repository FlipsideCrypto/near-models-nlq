{{ config(
    materialized = 'incremental',
    incremental_strategy = 'merge',
    merge_exclude_columns = ["inserted_timestamp"],
    unique_key = 'receipt_id',
    cluster_by = ['_inserted_timestamp::date', 'block_id'],
    tags = ['load', 'load_shards'],
    enabled = False
) }}
{# Disabled February 2024, no downstream usage #}
WITH chunks AS (

    SELECT
        *
    FROM
        {{ ref('silver__streamline_chunks') }}
    WHERE
        ARRAY_SIZE(receipts) > 0
        AND {{ incremental_load_filter('_inserted_timestamp') }}
),
chunk_receipts AS (
    SELECT
        block_id,
        shard_id,
        INDEX AS object_receipt_index,
        _load_timestamp,
        _partition_by_block_number,
        chunk_hash,
        VALUE AS receipt,
        _inserted_timestamp
    FROM
        chunks,
        LATERAL FLATTEN(
            input => receipts
        )
    WHERE
        ARRAY_SIZE(receipts) > 0
),
FINAL AS (
    SELECT
        receipt :receipt_id :: STRING AS receipt_id,
        block_id,
        shard_id,
        object_receipt_index AS receipt_index,
        chunk_hash,
        receipt,
        receipt :receiver_id :: STRING AS receiver_id,
        receipt :receipt :Action :signer_id :: STRING AS signer_id,
        LOWER(
            object_keys(
                receipt :receipt
            ) [0] :: STRING
        ) AS receipt_type,
        _load_timestamp,
        _partition_by_block_number,
        _inserted_timestamp
    FROM
        chunk_receipts
)
SELECT
    *,
    {{ dbt_utils.generate_surrogate_key(
        ['receipt_id']
    ) }} AS streamline_chunk_receipts_id,
    SYSDATE() AS inserted_timestamp,
    SYSDATE() AS modified_timestamp,
    '{{ invocation_id }}' AS _invocation_id
FROM
    FINAL
