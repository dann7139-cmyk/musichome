-- ============================================================
-- DARICEFY - 05_datos_iniciales.sql
-- Ejecutar QUINTO en Supabase SQL Editor
-- ============================================================

-- Asegurarnos de que default_commission tenga valor por defecto
ALTER TABLE public.countries ALTER COLUMN default_commission SET DEFAULT 10.0;

-- ─────────────────────────────────────────────────
-- PAÍSES CON COMISIONES
-- (incluye default_commission por compatibilidad)
-- ─────────────────────────────────────────────────
INSERT INTO public.countries
  (name, code, commission_rate, default_commission, currency_code, currency_symbol, payment_provider)
VALUES
  ('México',    'MXN', 10.0, 10.0, 'MXN', '$',  'mercadopago'),
  ('Colombia',  'COP', 10.0, 10.0, 'COP', '$',  'mercadopago'),
  ('Argentina', 'ARS', 10.0, 10.0, 'ARS', '$',  'mercadopago'),
  ('Chile',     'CLP', 10.0, 10.0, 'CLP', '$',  'mercadopago'),
  ('Perú',      'PEN', 10.0, 10.0, 'PEN', 'S/', 'mercadopago'),
  ('España',    'EUR', 10.0, 10.0, 'EUR', '€',  'stripe'),
  ('USA',       'USD', 10.0, 10.0, 'USD', '$',  'stripe')
ON CONFLICT DO NOTHING;

-- Sincronizar commission_rate con default_commission si ya había registros
UPDATE public.countries
SET commission_rate = default_commission
WHERE commission_rate IS NULL AND default_commission IS NOT NULL;

-- ─────────────────────────────────────────────────
-- MENSAJES MOTIVACIONALES
-- ─────────────────────────────────────────────────
INSERT INTO public.motivational_messages (week_number, message_es, category)
VALUES
  (1, 'Daricefy cree en tu talento. Sigue creciendo!', 'inspiracion'),
  (2, 'Tu musica transforma momentos ordinarios en recuerdos inolvidables.', 'motivacion'),
  (3, 'Tip: Responde en menos de 2 horas para destacar entre los mejores grupos.', 'consejo'),
  (4, 'Cada evento es una oportunidad para conseguir una resena de 5 estrellas.', 'consejo'),
  (5, 'Los grupos verificados reciben hasta 3x mas reservas. Ya solicitaste la tuya?', 'motivacion')
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────
-- VERIFICAR DATOS
-- ─────────────────────────────────────────────────
SELECT
  'Paises' AS tabla,
  COUNT(*) AS registros
FROM public.countries
UNION ALL
SELECT
  'Mensajes motivacionales',
  COUNT(*)
FROM public.motivational_messages;

SELECT 'Datos iniciales cargados correctamente' AS status;
