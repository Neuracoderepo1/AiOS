revoke insert, update, references on public.aios_tools from service_role;
grant insert (id, tool_key, name, description, version, category, risk_level, input_schema, output_schema, handler, status, is_enabled, requires_approval, timeout_ms, rate_limit, idempotency_required, external_service, capabilities, created_at, updated_at) on public.aios_tools to service_role;
grant update (id, tool_key, name, description, version, category, risk_level, input_schema, output_schema, handler, status, is_enabled, requires_approval, timeout_ms, rate_limit, idempotency_required, external_service, capabilities, created_at, updated_at) on public.aios_tools to service_role;
grant select (credential_reference) on public.aios_tools to service_role;
