-- ============================================================
-- sql/486_report_group_content.sql
-- 🚩 REPORTAR CONTENIDO DE UN PERFIL DE GRUPO (cierra el círculo del
-- takedown de los Términos §6: "si un titular nos notifica, retiramos").
--
-- El cliente (o cualquier usuario) reporta desde el perfil del grupo:
-- video/música que no es suya (derechos de autor), contenido
-- inapropiado o información falsa.
--
--   • Registra señal en fraud_signals sobre el DUEÑO del grupo
--     (severity medium si es derechos de autor, low si no).
--   • Notifica a los admins → tap abre la revisión de medios.
--   • Anti-abuso: máx 1 reporte por usuario por grupo cada 24h y
--     máx 5 reportes de contenido por usuario por día.
--   • NO retira nada automáticamente — tú decides en el panel
--     (quitar video, pedir cambio o suspender si reincide).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.report_group_content(
  p_group_id UUID,
  p_reason   TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_owner  UUID;
  v_gname  TEXT;
  v_admin  UUID;
  v_sev    TEXT;
BEGIN
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;
  IF p_group_id IS NULL OR COALESCE(TRIM(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_params');
  END IF;

  SELECT owner_id, name INTO v_owner, v_gname FROM groups WHERE id = p_group_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  -- 🛡️ Anti-abuso: 1 reporte por grupo cada 24h; 5 reportes al día en total
  IF EXISTS (
    SELECT 1 FROM fraud_signals
    WHERE signal_type = 'content_report'
      AND metadata->>'reported_by' = v_caller::text
      AND metadata->>'group_id'    = p_group_id::text
      AND created_at > NOW() - INTERVAL '24 hours'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Ya reportaste este perfil hoy. Nuestro equipo lo está revisando.');
  END IF;
  IF (SELECT COUNT(*) FROM fraud_signals
      WHERE signal_type = 'content_report'
        AND metadata->>'reported_by' = v_caller::text
        AND created_at > NOW() - INTERVAL '24 hours') >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      'Alcanzaste el límite de reportes por hoy.');
  END IF;

  v_sev := CASE WHEN p_reason ILIKE '%derechos%' OR p_reason ILIKE '%autor%'
                THEN 'medium' ELSE 'low' END;

  -- Señal sobre el dueño del grupo (evidencia + acumula en su historial)
  INSERT INTO fraud_signals (user_id, signal_type, severity, description, metadata)
  VALUES (v_owner, 'content_report', v_sev,
    format('Reporte de contenido del perfil "%s": %s', COALESCE(v_gname, '—'), LEFT(p_reason, 200)),
    jsonb_build_object('group_id', p_group_id, 'reported_by', v_caller, 'reason', LEFT(p_reason, 200)));

  -- Avisar a los admins → revisión de medios
  FOR v_admin IN SELECT id FROM profiles WHERE role = 'admin' LOOP
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (v_admin, 'admin',
      '🚩 Reporte de contenido',
      format('Un usuario reportó el perfil de %s: "%s". Revisa el contenido — si es reclamo de derechos de autor, retíralo primero (Términos §6).',
             COALESCE(v_gname, 'un grupo'), LEFT(p_reason, 140)),
      jsonb_build_object('group_id', p_group_id, 'screen', 'AdminMediaReview'));
  END LOOP;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.report_group_content(UUID, TEXT) TO authenticated;

COMMIT;

-- ── VERIFICACIÓN ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname = 'report_group_content';
-- Esperado: 1 fila

SELECT '486_report_group_content.sql ejecutado ✅' AS status;
