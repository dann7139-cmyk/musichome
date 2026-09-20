-- ============================================================================
-- sql/663_page_views_and_web_visit_stats.sql
--
-- Visitas a la web (petición real: "que me aparezca cuántas personas
-- visitan mi web... déjalo bien profesional"). Tabla ligera, sin datos
-- personales — solo ruta + un id de sesión aleatorio guardado en
-- localStorage del visitante (nunca IP ni identidad real). Cualquiera
-- puede insertar (INSERT-only, el beacon del sitio corre sin sesión);
-- solo el admin completo puede leer el resumen, y solo vía RPC
-- SECURITY DEFINER — nadie puede consultar la tabla directo.
-- ============================================================================

CREATE TABLE public.page_views (
  id bigserial PRIMARY KEY,
  path text NOT NULL,
  session_id text NOT NULL,
  referrer text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_page_views_created_at ON public.page_views(created_at);
ALTER TABLE public.page_views ENABLE ROW LEVEL SECURITY;
CREATE POLICY page_views_insert_anyone ON public.page_views FOR INSERT WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.get_web_visit_stats()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE
  v_role TEXT;
  v_result JSONB;
BEGIN
  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'total_views', (SELECT count(*) FROM page_views),
    'views_today', (SELECT count(*) FROM page_views WHERE created_at >= date_trunc('day', now())),
    'views_7d', (SELECT count(*) FROM page_views WHERE created_at >= now() - interval '7 days'),
    'views_30d', (SELECT count(*) FROM page_views WHERE created_at >= now() - interval '30 days'),
    'unique_sessions_30d', (SELECT count(DISTINCT session_id) FROM page_views WHERE created_at >= now() - interval '30 days'),
    'top_paths', COALESCE((
      SELECT jsonb_agg(row_to_json(t)) FROM (
        SELECT path, count(*) AS views
        FROM page_views WHERE created_at >= now() - interval '30 days'
        GROUP BY path ORDER BY count(*) DESC LIMIT 8
      ) t
    ), '[]'::jsonb),
    'daily_30d', COALESCE((
      SELECT jsonb_agg(row_to_json(t)) FROM (
        SELECT to_char(date_trunc('day', created_at), 'YYYY-MM-DD') AS day, count(*) AS views
        FROM page_views WHERE created_at >= now() - interval '30 days'
        GROUP BY 1 ORDER BY 1
      ) t
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$f$;
GRANT EXECUTE ON FUNCTION public.get_web_visit_stats() TO authenticated;
