begin;
revoke all on function private.aios_assert_invocation_executable(uuid) from public, anon, authenticated, service_role;
revoke all on function private.aios_mission_terminal_cascade() from public, anon, authenticated, service_role;
revoke all on function private.aios_task_mission_gate() from public, anon, authenticated, service_role;
commit;
