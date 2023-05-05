{{ config(
    materialized = 'incremental',
    unique_key = 'tx_hash'
) }}

WITH lockup_actions AS (

    SELECT
        *
    FROM
        {{ ref('silver__actions_events_function_call_s3') }}
    WHERE
        (
            receiver_id = 'lockup.near'
            OR signer_id = 'lockup.near'
        )
        AND method_name IN (
            'on_lockup_create',
            'create',
            'new'
        ) 
        and tx_hash not in (
            'Ez6rNL3fP62c4nMroYUmjVR4MbqEeVoL6RzmuajGQrkS',
            'TcCm1jzMFnwgAT3Wh2Qr1n2tR7ZVXKcv3ThKbXAhe7H'
        )
        {% if target.name == 'manual_fix' or target.name == 'manual_fix_dev' %}
            AND {{ partition_load_manual('no_buffer') }}
        {% else %}
            AND {{ incremental_load_filter('_load_timestamp') }}
        {% endif %}
),
lockup_xfers AS (
    SELECT
        *
    FROM
        {{ ref('silver__transfers_s3') }}
    WHERE
        tx_hash IN (
            SELECT
                DISTINCT tx_hash
            FROM
                lockup_actions
        ) {% if target.name == 'manual_fix' or target.name == 'manual_fix_dev' %}
            AND {{ partition_load_manual('no_buffer') }}
        {% else %}
            AND {{ incremental_load_filter('_load_timestamp') }}
        {% endif %}
),
tx_status as (
    select
    tx_hash,
    tx_status,
    _load_timestamp
    _partition_by_block_number
    from {{ref('silver__streamline_transactions_final')}}
    {% if target.name == 'manual_fix' or target.name == 'manual_fix_dev' %}
            WHERE {{ partition_load_manual('no_buffer') }}
        {% else %}
            WHERE {{ incremental_load_filter('_load_timestamp') }}
        {% endif %}
)
method_on_lockup_create AS (
    SELECT
        tx_hash,
        SPLIT(
            action_id,
            '-'
        ) [0] :: STRING AS receipt_object_id,
        block_timestamp,
        block_id,
        signer_id,
        args,
        args :attached_deposit :: DOUBLE * 1e-24 AS deposit,
        args :lockup_account_id :: STRING AS lockup_account_id,
        _load_timestamp,
        _partition_by_block_number
    FROM
        lockup_actions
    WHERE
        method_name = 'on_lockup_create'
        AND receiver_id = 'lockup.near'
),
method_create AS (
    SELECT
        tx_hash,
        SPLIT(
            action_id,
            '-'
        ) [0] :: STRING AS receipt_object_id,
        block_timestamp,
        block_id,
        signer_id,
        deposit * 1e-24 AS deposit,
        args,
        args :owner_account_id :: STRING AS owner_account_id,
        args :lockup_duration :: STRING AS lockup_duration,
        args :lockup_timestamp :: STRING AS lockup_timestamp,
        TO_TIMESTAMP_NTZ(args :lockup_timestamp) AS lockup_timestamp_ntz,
        args :vesting_schedule :: STRING AS vesting_schedule,
        args :release_duration :: STRING AS release_duration,
        _load_timestamp,
        _partition_by_block_number
    FROM
        lockup_actions
    WHERE
        method_name = 'create'
        AND receiver_id = 'lockup.near'
),
method_early_new AS (
    SELECT
        fc.tx_hash,
        SPLIT(
            fc.action_id,
            '-'
        ) [0] :: STRING AS receipt_object_id,
        fc.block_timestamp,
        fc.block_id,
        fc.signer_id,
        fc.receiver_id AS lockup_account_id,
        xf.deposit * 1e-24 AS deposit,
        args,
        args :foundation_account_id :: STRING AS foundation_account_id,
        args :owner_account_id :: STRING AS owner_account_id,
        args :lockup_duration :: STRING AS lockup_duration,
        args :lockup_timestamp :: STRING AS lockup_timestamp,
        TO_TIMESTAMP_NTZ(args :lockup_timestamp) AS lockup_timestamp_ntz,
        args :vesting_schedule :: STRING AS vesting_schedule,
        args :release_duration :: STRING AS release_duration,
        fc._load_timestamp,
        fc._partition_by_block_number
    FROM
        lockup_actions fc
        LEFT JOIN near.silver.transfers_s3 xf
        ON SPLIT(
            fc.action_id,
            '-'
        ) [0] :: STRING = SPLIT(
            xf.action_id,
            '-'
        ) [0] :: STRING
    WHERE
        signer_id = 'lockup.near'
        AND method_name = 'new'
),
join_current_methods AS (
    SELECT
        olc.tx_hash,
        olc.receipt_object_id AS receipt_object_id_olc,
        C.receipt_object_id AS receipt_object_id_c,
        olc.block_timestamp,
        olc.block_id,
        olc.signer_id,
        C.deposit,
        olc.lockup_account_id,
        C.owner_account_id,
        C.lockup_duration,
        C.lockup_timestamp,
        C.lockup_timestamp_ntz,
        C.release_duration,
        C.vesting_schedule,
        olc.args AS olc_args,
        C.args AS c_args,
        _load_timestamp,
        _partition_by_block_number
    FROM
        method_on_lockup_create olc
        LEFT JOIN method_create C USING (tx_hash)
),
FINAL AS (
    SELECT
        tx_hash,
        block_timestamp,
        block_id,
        signer_id,
        deposit,
        lockup_account_id,
        owner_account_id,
        lockup_duration,
        lockup_timestamp,
        lockup_timestamp_ntz,
        release_duration,
        vesting_schedule,
        _load_timestamp,
        _partition_by_block_number
    FROM
        join_current_methods
    UNION ALL
    SELECT
        tx_hash,
        block_timestamp,
        block_id,
        signer_id,
        deposit,
        lockup_account_id,
        owner_account_id,
        lockup_duration,
        lockup_timestamp,
        lockup_timestamp_ntz,
        release_duration,
        vesting_schedule,
        _load_timestamp,
        _partition_by_block_number
    FROM
        method_early_new
)
SELECT
    *
FROM
    FINAL
