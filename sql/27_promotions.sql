-- ══════════════════════════════════════════════════════════════════════════════
-- 27_promotions.sql
-- Sistema de publicidad editable + mensajes de contacto.
-- Ejecutar en Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Tabla: promotions ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS promotions (
  id          uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  title       text        NOT NULL,
  subtitle    text,
  emoji       text        DEFAULT '🎵',
  tag         text        DEFAULT 'PUBLICIDAD',
  button_text text        DEFAULT 'Contactar',
  link_type   text        DEFAULT 'none'
              CHECK (link_type IN ('none', 'group', 'talent')),
  link_id     uuid,
  is_active   boolean     DEFAULT true,
  order_index int         DEFAULT 0,
  created_at  timestamptz DEFAULT now()
);

-- Dato inicial para no mostrar pantalla vacía
INSERT INTO promotions (title, subtitle, emoji, tag, button_text, link_type, is_active, order_index)
VALUES (
  'Llega a miles de clientes',
  'Promociona tu negocio en Daricefy',
  '🎵',
  'ESPACIO PUBLICITARIO',
  'Contactar',
  'none',
  true,
  0
) ON CONFLICT DO NOTHING;

-- ── 2. Tabla: ad_messages ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ad_messages (
  id            uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  promotion_id  uuid        REFERENCES promotions(id) ON DELETE SET NULL,
  sender_id     uuid        REFERENCES profiles(id)   ON DELETE SET NULL,
  sender_name   text,
  sender_phone  text,
  message       text        NOT NULL,
  is_read       boolean     DEFAULT false,
  created_at    timestamptz DEFAULT now()
);

-- ── 3. RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE promotions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE ad_messages ENABLE ROW LEVEL SECURITY;

-- Cualquiera puede leer promociones activas
CREATE POLICY "Public can view active promotions"
  ON promotions FOR SELECT
  USING (is_active = true OR EXISTS (
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ));

-- Admin puede hacer todo en promotions
CREATE POLICY "Admin full access promotions"
  ON promotions FOR ALL
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

-- Cualquier usuario autenticado puede insertar mensaje
CREATE POLICY "Authenticated can insert ad_messages"
  ON ad_messages FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

-- Solo admin puede leer/actualizar mensajes
CREATE POLICY "Admin can view ad_messages"
  ON ad_messages FOR SELECT
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admin can update ad_messages"
  ON ad_messages FOR UPDATE
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));
