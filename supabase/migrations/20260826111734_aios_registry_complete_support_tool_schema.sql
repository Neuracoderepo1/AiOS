UPDATE public.aios_tools
SET input_schema = jsonb_build_object(
  'type','object',
  'required',jsonb_build_array('limit'),
  'additionalProperties',false,
  'properties',jsonb_build_object(
    'limit',jsonb_build_object('type','integer','minimum',1,'maximum',50),
    'query',jsonb_build_object('type','string','maxLength',200),
    'filters',jsonb_build_object(
      'type','object',
      'additionalProperties',false,
      'properties',jsonb_build_object(
        'category',jsonb_build_object('type','string','maxLength',100),
        'created_after',jsonb_build_object('type','string','maxLength',64),
        'created_before',jsonb_build_object('type','string','maxLength',64)
      )
    )
  )
),
updated_at=now()
WHERE tool_key='support.search_tickets';
