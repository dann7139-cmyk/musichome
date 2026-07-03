-- ════════════════════════════════════════════════════════════════════
-- sql/411_test_express_proposals_for_client.sql
--
-- Inserta solicitudes en negociación + propuestas para que el cliente
-- vea el ProposalCarousel.
--
-- Lógica igual a producción:
--   • Las solicitudes usan el estado del cliente (location_estado)
--   • Solo se invitan grupos del mismo estado (igual que el dispatch real)
--
-- Para apuntar a un cliente específico descomenta la línea de email ↓
-- Requisito previo: sql/410 aplicado.
-- ════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_client_id     UUID;
  v_client_state  TEXT;
  v_client_city   TEXT;
  v_req_id        UUID;
  v_req_ids       UUID[] := '{}';
  rec             RECORD;
  i               INT := 1;
  v_pph           NUMERIC;
  v_travel        NUMERIC;
  v_base          NUMERIC;
  v_total         NUMERIC;
  v_fee           NUMERIC;

  -- Datos de prueba (máximo 4 grupos)
  v_event_types TEXT[]    := ARRAY['Cumpleaños',    'Boda',                         'Quinceañera',                  'Empresa'];
  v_hours_arr   INT[]     := ARRAY[3,               4,                              5,                              3];
  v_guests_arr  INT[]     := ARRAY[60,              150,                            250,                            40];
  v_pph_arr     NUMERIC[] := ARRAY[2500,            3800,                           4200,                           2200];
  v_travel_arr  NUMERIC[] := ARRAY[300,             600,                            900,                            150];
  v_arrivals    TEXT[]    := ARRAY['18:30',         '19:00',                        '20:00',                        '18:00'];
  v_starts      TEXT[]    := ARRAY['19:00',         '20:00',                        '21:00',                        '19:00'];
  v_notes       TEXT[]    := ARRAY[
    'Sonido y luces incluidas. Repertorio de 3 horas sin parar.',
    'Especialistas en bodas. Incluye serenata de entrada y vals.',
    'Banda de 10 músicos. Éxitos del momento y clásicos del género.',
    'Show adaptado para eventos corporativos. Música ambiente + show.'
  ];
BEGIN

  -- ── 1. Obtener cliente y su estado ───────────────────────────────────────
  SELECT p.id, p.state, p.city
  INTO   v_client_id, v_client_state, v_client_city
  FROM   auth.users u
  JOIN   public.profiles p ON p.id = u.id
  WHERE  p.role = 'client'
  -- AND u.email = 'cliente@ejemplo.com'   ← descomenta para cliente específico
  ORDER  BY p.created_at DESC
  LIMIT  1;

  IF v_client_id IS NULL THEN
    RAISE EXCEPTION '❌ No se encontró ningún cliente.';
  END IF;

  RAISE NOTICE '👤 Cliente: %  |  Estado: %  |  Ciudad: %',
    v_client_id, v_client_state, v_client_city;

  -- ── 2. Cancelar solicitudes activas previas ───────────────────────────────
  UPDATE public.event_requests
  SET    status = 'cancelled'
  WHERE  client_id = v_client_id
    AND  status IN ('open', 'en_negociacion', 'negotiating', 'expired');

  RAISE NOTICE '🧹 Solicitudes previas canceladas';

  -- Desactivar triggers de usuario (evita límite de 3 solicitudes activas)
  ALTER TABLE public.event_requests DISABLE TRIGGER USER;

  -- ── 3. Un request + propuesta por cada grupo del mismo estado ────────────
  FOR rec IN (
    SELECT g.id,
           g.owner_id,
           g.name,
           g.genre,
           COALESCE(g.city,  v_client_city,  'Ciudad') AS city,
           COALESCE(g.state, v_client_state, 'Estado') AS state
    FROM   public.groups g
    WHERE  g.owner_id IS NOT NULL
    ORDER  BY g.created_at DESC
    LIMIT  4
  )
  LOOP
    v_pph    := v_pph_arr[i];
    v_travel := v_travel_arr[i];
    v_base   := v_pph * v_hours_arr[i];
    v_total  := v_base + v_travel;
    v_fee    := ROUND(v_total * 0.20);

    -- Insertar event_request con el estado del CLIENTE (como en producción)
    INSERT INTO public.event_requests (
      client_id,
      event_type,
      genre,
      event_date,
      hours,
      guest_count,
      location_city,
      location_estado,
      status,
      expires_at,
      negotiating_group_id,
      proposal_data
    ) VALUES (
      v_client_id,
      v_event_types[i],
      rec.genre,
      (NOW() + (i * interval '3 days'))::date,
      v_hours_arr[i],
      v_guests_arr[i],
      COALESCE(v_client_city,  rec.city,  'Ciudad'),
      COALESCE(v_client_state, rec.state, 'Estado'),
      'en_negociacion',
      NOW() + interval '48 hours',
      rec.owner_id,
      jsonb_build_object(
        'price_per_hour', v_pph,
        'travel_cost',    v_travel,
        'total_amount',   v_total + v_fee,
        'group_earnings', v_total
      )
    )
    RETURNING id INTO v_req_id;

    v_req_ids := array_append(v_req_ids, v_req_id);

    -- Insertar propuesta del grupo
    INSERT INTO public.event_request_proposals (
      request_id,
      group_id,
      group_owner_id,
      proposal_data
    ) VALUES (
      v_req_id,
      rec.id,
      rec.owner_id,
      jsonb_build_object(
        'price_per_hour',    v_pph,
        'travel_cost',       v_travel,
        'base_price',        v_base,
        'base_total',        v_total,
        'demand_multiplier', 1.0,
        'group_price',       v_total,
        'express_fee',       v_fee,
        'total_amount',      v_total + v_fee,
        'group_earnings',    v_total,
        'arrival_time',      v_arrivals[i],
        'start_time',        v_starts[i],
        'notes',             v_notes[i]
      )
    )
    ON CONFLICT (request_id, group_id) DO UPDATE
      SET proposal_data = EXCLUDED.proposal_data,
          updated_at    = NOW();

    RAISE NOTICE '  ✅ Slot % — grupo: % (%) | evento: % | total: $%',
      i, rec.name, rec.state, v_event_types[i], (v_total + v_fee)::INT;

    i := i + 1;
  END LOOP;

  -- Reactivar triggers
  ALTER TABLE public.event_requests ENABLE TRIGGER USER;

  IF i = 1 THEN
    RAISE EXCEPTION '❌ No se encontraron grupos con owner_id. Crea al menos un grupo.';
  END IF;

  RAISE NOTICE '';
  RAISE NOTICE '🎉 % propuestas creadas para cliente %. Abre la app para ver el carousel.',
    i - 1, v_client_id;

END;
$$;

SELECT '411_test_express_proposals_for_client ✅' AS status;


-- ════════════════════════════════════════════════════════════════════
-- LIMPIEZA — ejecutar por separado para borrar los datos de prueba
-- ════════════════════════════════════════════════════════════════════
/*
UPDATE public.event_requests
SET    status = 'cancelled'
WHERE  status = 'en_negociacion'
  AND  event_type IN ('Cumpleaños', 'Boda', 'Quinceañera', 'Empresa')
  AND  created_at > NOW() - interval '2 hours';
*/
