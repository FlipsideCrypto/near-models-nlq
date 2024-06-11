{{ config(
  materialized = 'incremental',
  incremental_strategy = 'merge',
  merge_exclude_columns = ["inserted_timestamp"],
  unique_key = 'action_id',
  cluster_by = ['block_timestamp::DATE', '_inserted_timestamp::DATE'],
  tags = ['actions', 'curated','scheduled_non_core']
) }}

{# NOTE - used downstream in Social models, no longer a gold view on just this #}

WITH action_events AS (

  SELECT
    action_id,
    tx_hash,
    block_id,
    block_timestamp,
    action_data,
    _partition_by_block_number,
    _inserted_timestamp,
    modified_timestamp AS _modified_timestamp
  FROM
    {{ ref('silver__actions_events_s3') }}
  WHERE
    action_name = 'AddKey' 
    {% if var("MANUAL_FIX") %}
      AND {{ partition_load_manual('no_buffer') }}
    {% else %}
      {% if var('IS_MIGRATION') %}
        AND {{ incremental_load_filter('_inserted_timestamp') }}
      {% else %}
        AND {{ incremental_load_filter('_modified_timestamp') }}
      {% endif %}
    {% endif %}
),
addkey_events AS (
  SELECT
    action_id,
    tx_hash,
    block_id,
    block_timestamp,
    action_data :access_key :nonce :: NUMBER AS nonce,
    action_data :public_key :: STRING AS public_key,
    action_data :access_key :permission AS permission,
    action_data :access_key :permission :FunctionCall :allowance :: FLOAT AS allowance,
    action_data :access_key :permission :FunctionCall :method_names :: ARRAY AS method_name,
    action_data :access_key :permission :FunctionCall :receiver_id :: STRING AS receiver_id,
    _partition_by_block_number,
    _inserted_timestamp,
    _modified_timestamp
  FROM
    action_events
)
SELECT
  *,
  {{ dbt_utils.generate_surrogate_key(
    ['action_id']
  ) }} AS actions_events_addkey_id,
  SYSDATE() AS inserted_timestamp,
  SYSDATE() AS modified_timestamp,
  '{{ invocation_id }}' AS _invocation_id
FROM
  addkey_events
