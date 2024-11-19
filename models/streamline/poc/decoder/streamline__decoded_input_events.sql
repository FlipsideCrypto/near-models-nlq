{{ config (
    materialized = "view",
) }}

SELECT 
    block_id,
    tx_hash,
    receipt_actions:receipt:Action:actions[0]:FunctionCall:args::string as encoded_event,
    '{"recipient_address": "Bytes(20)", "amount": "U128"}' as event_struct
FROM near.silver.streamline_receipts_final
WHERE block_timestamp >= sysdate() - INTERVAL '2 weeks'
AND signer_id = 'relay.aurora'
AND object_keys(receipt_actions:receipt:Action:actions[0])[0] = 'FunctionCall'
AND receipt_actions:receipt:Action:actions[0]:FunctionCall:method_name::STRING = 'withdraw'
LIMIT 100