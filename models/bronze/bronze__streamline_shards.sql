{{ config (
    materialized = 'view',
    tags = ['load', 'load_shards']
) }}

WITH external_shards AS (

    SELECT
        metadata$filename AS _filename,
        SPLIT(
            _filename,
            '/'
        ) [0] :: NUMBER AS block_id,
        SYSDATE() AS _load_timestamp,
        RIGHT(SPLIT(_filename, '.') [0], 1) :: NUMBER AS _shard_number,
        VALUE,
        _partition_by_block_number
    FROM
        {{ source(
            "streamline",
            "shards"
        ) }}
),
meta AS (
    SELECT
        job_created_time AS _inserted_timestamp,
        file_name AS _filename
    FROM
        TABLE(
            information_schema.external_table_file_registration_history(
                start_time => DATEADD('day', -2, SYSDATE()),
                table_name => '{{ source( 'streamline', 'shards' ) }}')
            ) A
),
FINAL AS (
    SELECT
        e._filename,
        e.block_id,
        e._load_timestamp,
        e._shard_number,
        e.value,
        e._partition_by_block_number,
        m._inserted_timestamp
    FROM
        external_shards e
        LEFT JOIN meta m USING (
            _filename
        )
)
SELECT
    *
FROM
    FINAL
