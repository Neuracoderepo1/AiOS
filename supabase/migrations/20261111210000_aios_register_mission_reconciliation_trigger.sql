-- Register the new task completion enqueue trigger in the restoration drift inventory.
-- The trigger is intentionally non-restorable: it must remain enabled during every restoration window.
select private.aios_guard_register_table('public','aios_tasks');
