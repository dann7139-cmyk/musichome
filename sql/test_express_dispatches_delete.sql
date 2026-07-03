-- Limpia las solicitudes de prueba
-- Ejecutar en: Supabase Dashboard → SQL Editor

DELETE FROM public.express_dispatches
WHERE request_id IN (
  SELECT id FROM public.event_requests
  WHERE comments LIKE '🧪%'
);

DELETE FROM public.event_requests
WHERE comments LIKE '🧪%';
